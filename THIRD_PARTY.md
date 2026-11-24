# Third-party components

Every dependency gets a row when it is added (CLAUDE.md, docs/10). Licences
below were read from each repository's GitHub metadata on the date shown;
`NOASSERTION` means GitHub could not identify a single licence and the files
must be read by hand before the component ships.

## Shipped in Seemless.app (WP8.5)

`scripts/release/gen_notices.py` reads this table to write
`Contents/Resources/Licenses/THIRD-PARTY-NOTICES.md` and to copy each
licence file into the app; a missing file fails the release build. Paths are
relative to the repository (`build/src/<name>` is the checkout of the pin in
`scripts/versions.lock`). Libraries that come from Homebrew are listed per
release in `Contents/Resources/Licenses/homebrew-libraries.tsv` (written by
`scripts/release/bundle_stack.py` from `brew info`), not here.
`scripts/release/source-archive.sh` builds the source offer for every row
plus the Homebrew libraries.

| Component | Version / SHA | Licence | Source | Licence files | In the app as |
|-----------|---------------|---------|--------|---------------|---------------|
| QEMU (utmapp/qemu `utm-edition`) | `8ab298b` + `patches/qemu/` | GPL-2.0-only; some files LGPL-2.1 / BSD / MIT (`LICENSE`) | https://github.com/utmapp/qemu | build/src/qemu/COPYING, build/src/qemu/COPYING.LIB, build/src/qemu/LICENSE | `Helpers/qemu-system-aarch64`, `Helpers/qemu-img` (separate executables) |
| EDK II firmware (QEMU `pc-bios`, `roms/edk2` `4dfdca6`) | QEMU's prebuilt `edk2-aarch64-code.fd` | BSD-2-Clause-Patent plus the licences in `edk2-licenses.txt` | https://github.com/tianocore/edk2 | build/src/qemu/pc-bios/edk2-licenses.txt | `Resources/qemu/edk2-aarch64-code.fd` |
| iPXE (QEMU `pc-bios`, `roms/ipxe` `4bd064d`) | QEMU's prebuilt `efi-virtio.rom` | GPL-2.0-or-later (parts UBDL) | https://github.com/ipxe/ipxe | build/src/qemu/roms/ipxe/COPYING, build/src/qemu/roms/ipxe/COPYING.GPLv2, build/src/qemu/roms/ipxe/COPYING.UBDL | `Resources/qemu/efi-virtio.rom` (virtio-net option ROM) |
| utmapp/virglrenderer (`macos-next`) | `dd0652b` + `patches/virglrenderer/` | MIT (`COPYING`); Neptune files' own headers still to check | https://github.com/utmapp/virglrenderer | build/src/virglrenderer/COPYING | `Frameworks/libvirglrenderer.1.dylib`, `Helpers/virgl_render_server` |
| utmapp/libepoxy (`macos-venus`) | `15d904d` | MIT | https://github.com/utmapp/libepoxy | build/src/libepoxy/COPYING | `Frameworks/libepoxy.0.dylib` |
| ANGLE (utmapp/WebKit, `Source/ThirdParty/ANGLE`) | `6a7f464` | BSD-3-Clause | https://github.com/utmapp/WebKit | build/src/webkit-angle/Source/ThirdParty/ANGLE/LICENSE | `Frameworks/libEGL.dylib`, `Frameworks/libGLESv2.dylib` |
| utmapp/dxmt | `1fe2e75` | LGPL-2.1-or-later | https://github.com/utmapp/dxmt | build/src/dxmt/LICENSE, build/src/dxmt/COPYING.LIB | `Frameworks/libdxmt-native.dylib` (replaceable dylib) |
| osy/vkd3d-proton (`neptune`) | `a8b7cd4` + `patches/vkd3d-proton-npt/` | LGPL-2.1 | https://github.com/osy/vkd3d-proton | build/src/vkd3d-proton-npt/COPYING, build/src/vkd3d-proton-npt/LICENSE, build/src/vkd3d-proton-npt/AUTHORS | `Frameworks/libvkd3d-proton-d3d12.dylib`, `-d3d12core.dylib` (replaceable dylibs) |
| dxil-spirv | `7ecda13` | MIT | https://github.com/HansKristian-Work/dxil-spirv | build/src/vkd3d-proton-npt/subprojects/dxil-spirv/LICENSE.MIT | In d3d12core |
| dxbc-spirv | `d5b0643` | MIT | https://github.com/doitsujin/dxbc-spirv | build/src/vkd3d-proton-npt/subprojects/dxil-spirv/subprojects/dxbc-spirv/LICENSE | In d3d12core |
| SPIRV-Cross (dxil-spirv's) | `4b7bcb7` | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Cross | build/src/vkd3d-proton-npt/subprojects/dxil-spirv/third_party/SPIRV-Cross/LICENSE | In d3d12core |
| SPIRV-Tools (dxil-spirv's) | `199cb20` | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Tools | build/src/vkd3d-proton-npt/subprojects/dxil-spirv/third_party/SPIRV-Tools/LICENSE | In d3d12core |
| osy/directx-native | `7258be1` | Apache-2.0 | https://github.com/osy/directx-native | build/src/directx-native/LICENSE | In d3d12core and DXMT |
| KhronosGroup/MoltenVK | v1.4.2 `db66022` + `patches/moltenvk/` | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK | build/src/moltenvk/LICENSE | `Frameworks/libMoltenVK.dylib` |
| SPIRV-Cross (MoltenVK's) | `6c09849` | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Cross | build/src/mvk-spirv-cross/LICENSE | In MoltenVK |
| SPIRV-Tools (MoltenVK's) | `0d6fd73` | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Tools | build/src/mvk-spirv-tools/LICENSE | In MoltenVK |
| SPIRV-Headers (MoltenVK's) | `29981f6` | MIT-style Khronos licence | https://github.com/KhronosGroup/SPIRV-Headers | build/src/mvk-spirv-headers/LICENSE | In MoltenVK |
| cereal | `a56bad8` | BSD-3-Clause | https://github.com/USCiLab/cereal | build/src/mvk-cereal/LICENSE | In MoltenVK |
| stefanberger/swtpm | v0.10.2 `32b5a05` | BSD-3-Clause | https://github.com/stefanberger/swtpm | build/src/swtpm/LICENSE | `Helpers/swtpm`, `Frameworks/libswtpm_libtpms.0.dylib` |
| stefanberger/libtpms | v0.10.2 `03ff248` | IBM BSD-3-Clause-style (library, TPM 1.2); TCG BSD-style licence for the TPM 2.0 code, which grants **no patent licence** (`LICENSE`, read 2026-11-24) | https://github.com/stefanberger/libtpms | build/src/libtpms/LICENSE | `Frameworks/libtpms.0.dylib` |
| swift-protobuf | 1.41.0 | Apache-2.0 | https://github.com/apple/swift-protobuf | kit/.build/checkouts/swift-protobuf/LICENSE.txt | In the app and `seemlessctl` |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser | kit/.build/checkouts/swift-argument-parser/LICENSE.txt | In `Helpers/seemlessctl` |

## In use

| Component | Version / SHA | Licence | Source | Used by |
|-----------|---------------|---------|--------|---------|
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser | `seemlessctl` |
| swift-protobuf | 1.41.0 (`fed2f76`) | Apache-2.0 | https://github.com/apple/swift-protobuf | `SeemlessKit` runtime for the agent protocol; its `protoc-gen-swift` runs at dev time only (`scripts/gen-proto.sh`) |
| prost, prost-derive | 0.14.6 | Apache-2.0 | https://github.com/tokio-rs/prost | Guest agent `proto` crate (ships in the agent) |
| bytes | 1.12.2 | MIT | https://github.com/tokio-rs/bytes | prost runtime dependency (ships in the agent) |
| prost-build, prost-types | 0.14.6 | Apache-2.0 | https://github.com/tokio-rs/prost | Build time only (`proto/build.rs`, `protogen`) |
| protox | 0.10.0 | MIT OR Apache-2.0 | https://github.com/andrewhickman/protox | Build time only: pure-Rust .proto compiler, so no `protoc` is needed |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 | https://github.com/microsoft/windows-rs | Guest agent transport and svc crates: Win32 bindings, Windows target only (WP4.2) |
| serde (derive), serde_json, toml | 1.0.229, 1.0.154, 0.9.12 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde, https://github.com/serde-rs/json, https://github.com/toml-rs/toml | Guest agent `windows-model` only: `rules.toml` and the dump format (WP5.1) |
| osy/vkd3d-proton (`neptune`) | `a8b7cd4` + `patches/vkd3d-proton-npt/` | LGPL-2.1 | https://github.com/osy/vkd3d-proton | D3D12 backend for `NPT_D3D12_LIBRARY_PATH` (WP7.5): `libvkd3d-proton-d3d12.dylib` + `-d3d12core`. Ship as a separately replaceable dylib with source |
| dxil-spirv | `7ecda13` (vkd3d-proton submodule) | MIT (`LICENSE.MIT`) | https://github.com/HansKristian-Work/dxil-spirv | Statically linked into d3d12core |
| dxbc-spirv | `d5b0643` (dxil-spirv submodule) | MIT | https://github.com/doitsujin/dxbc-spirv | Statically linked into d3d12core |
| SPIRV-Tools, SPIRV-Headers (vkd3d-proton's) | `199cb20`, `c63848e` / `f88a2d7` | Apache-2.0; SPIRV-Headers MIT-style Khronos licence (`LICENSE`, read 2026-11-24) | https://github.com/KhronosGroup | Build inputs of dxil-spirv / vkd3d-proton |
| Vulkan-Headers | `0e9de56` (vkd3d-proton), `e3b1eec` (MoltenVK) | Apache-2.0 or MIT per file (`LICENSE.md`) | https://github.com/KhronosGroup/Vulkan-Headers | Headers only |
| osy/directx-native | `7258be1` | Apache-2.0 | https://github.com/osy/directx-native | Statically linked into d3d12core (events, shared-resource contract); DXMT links the same revision |
| KhronosGroup/MoltenVK | v1.4.2 `db66022` + `patches/moltenvk/` | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK | `libMoltenVK.dylib`, loaded by vkd3d-proton directly (WP7.5) |
| SPIRV-Cross (MoltenVK's) | `6c09849` | Apache-2.0 | https://github.com/KhronosGroup/SPIRV-Cross | Statically linked into MoltenVK |
| SPIRV-Tools, SPIRV-Headers (MoltenVK's) | `0d6fd73`, `29981f6` | Apache-2.0; MIT-style Khronos licence | https://github.com/KhronosGroup | Statically linked into MoltenVK |
| cereal | `a56bad8` | BSD-3-Clause | https://github.com/USCiLab/cereal | Header-only, compiled into MoltenVK (pipeline cache) |

Transitive Rust crates are listed with licences by
`cargo tree -p proto -p protogen -e normal,build --format "{p} {l}"`; at
WP4.1 every one was MIT, Apache-2.0, Unlicense OR MIT, or carried the
Unicode-3.0 data licence (unicode-ident). Only prost, prost-derive and bytes
(plus proc-macro crates used while compiling) reach the agent binary.

## Planned (pinned in `scripts/versions.lock`, not shipped in the app)

| Component | Licence (GitHub metadata, 2026-11-23) | Notes |
|-----------|----------------------------------------|-------|
| HansKristian-Work/vkd3d-proton v3.1 | LGPL-2.1 | S8 spike only; the product uses the neptune fork above |
| utmapp/d3dmetal-native | MIT | Optional; the Apple framework it loads is never bundled |
| osy/kvm-guest-drivers-windows (`neptune`) | BSD-2-Clause | Guest drivers |
| osy/virtio-win-mesa (`neptune`) | none reported; Mesa is MIT | Must be read before bundling |
| osy/build-mesa | none reported | Build scripts only |
| osy/neptune-protocol | Apache-2.0 | Code generator |

## Build tools (on the Mac, not shipped)

| Tool | Version | Licence | Source | Used for |
|------|---------|---------|--------|----------|
| cargo-xwin | 0.24.1 | MIT (crate metadata) | https://github.com/rust-cross/cargo-xwin | Windows build of the guest agent (WP4.2); its first build downloads Microsoft's CRT/SDK under Microsoft's licence (owner's decision, never bundled) |
| rustup target `aarch64-pc-windows-msvc` | toolchain 1.99.1 | MIT OR Apache-2.0 (Rust) | https://rust-lang.org | Same |

## Never bundled

Windows media, product keys, Microsoft tools (DISM, oscdimg, ADK),
Apple's `D3DMetal.framework`, Tiny11 Builder code or binaries (no licence).
