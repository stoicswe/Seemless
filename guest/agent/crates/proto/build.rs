// Generates the protocol types from /proto/seemless.proto (docs/06).
fn main() {
    let proto_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../proto");
    println!("cargo:rerun-if-changed={proto_dir}/seemless.proto");
    let fds = protox::compile(["seemless.proto"], [proto_dir]).expect("compile /proto/seemless.proto");
    prost_build::Config::new()
        .compile_fds(fds)
        .expect("generate Rust protocol types");
}
