//! protogen: a stand-in for `protoc --plugin=... --x_out=...`.
//!
//! Compiles the .proto files with protox (pure Rust), hands the plugin a
//! `CodeGeneratorRequest` on stdin, and writes the files from its
//! `CodeGeneratorResponse`. This lets `scripts/gen-proto.sh` generate the
//! Swift types with `protoc-gen-swift` without installing protoc.
//!
//! Usage: protogen --plugin <path> --proto-dir <dir> --out <dir> [--param <p>] <file.proto>...

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use prost::Message;
use prost_types::compiler::{CodeGeneratorRequest, CodeGeneratorResponse};

fn main() {
    if let Err(e) = run() {
        eprintln!("protogen: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut plugin = None;
    let mut proto_dir = None;
    let mut out = None;
    let mut param = None;
    let mut files = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--plugin" => plugin = Some(PathBuf::from(value()?)),
            "--proto-dir" => proto_dir = Some(PathBuf::from(value()?)),
            "--out" => out = Some(PathBuf::from(value()?)),
            "--param" => param = Some(value()?),
            _ if arg.starts_with("--") => return Err(format!("unknown option {arg}")),
            _ => files.push(arg),
        }
    }
    let plugin = plugin.ok_or("--plugin is required")?;
    let proto_dir = proto_dir.ok_or("--proto-dir is required")?;
    let out = out.ok_or("--out is required")?;
    if files.is_empty() {
        return Err("no .proto files given".into());
    }

    let mut compiler = protox::Compiler::new([&proto_dir]).map_err(|e| e.to_string())?;
    compiler.include_imports(true).include_source_info(true);
    for f in &files {
        compiler.open_file(f).map_err(|e| e.to_string())?;
    }
    let request = CodeGeneratorRequest {
        file_to_generate: files.clone(),
        parameter: param,
        proto_file: compiler.file_descriptor_set().file,
        // protox implements the protoc 3.x/2x language; plugins warn without a version.
        compiler_version: Some(prost_types::compiler::Version {
            major: Some(32),
            minor: Some(0),
            patch: Some(0),
            suffix: Some("protox".into()),
        }),
        ..Default::default()
    };

    let mut child = Command::new(&plugin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("start {}: {e}", plugin.display()))?;
    child.stdin.take().unwrap().write_all(&request.encode_to_vec()).map_err(|e| e.to_string())?;
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("{} exited with {}", plugin.display(), output.status));
    }
    let response = CodeGeneratorResponse::decode(output.stdout.as_slice()).map_err(|e| e.to_string())?;
    if let Some(error) = response.error {
        return Err(format!("plugin error: {error}"));
    }
    for file in response.file {
        let name = file.name.ok_or("plugin returned a file without a name")?;
        if name.contains("..") || name.starts_with('/') {
            return Err(format!("plugin returned an unsafe path {name}"));
        }
        let path = out.join(&name);
        std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(&path, file.content.unwrap_or_default()).map_err(|e| e.to_string())?;
        println!("wrote {}", path.display());
    }
    Ok(())
}
