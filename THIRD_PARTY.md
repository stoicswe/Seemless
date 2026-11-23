# Third-party components

Every dependency gets a row when it is added (CLAUDE.md, docs/10). Licences
below were read from each repository's GitHub metadata on the date shown;
`NOASSERTION` means GitHub could not identify a single licence and the files
must be read by hand before the component ships.

## In use

| Component | Version / SHA | Licence | Source | Used by |
|-----------|---------------|---------|--------|---------|
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser | `seemlessctl` |

## Planned (pinned as candidates in `scripts/versions.lock`, not yet built)

| Component | Licence (GitHub metadata, 2026-11-23) | Notes |
|-----------|----------------------------------------|-------|
| utmapp/qemu (`utm-edition`) | NOASSERTION; QEMU is GPLv2 overall | Separate executable only (docs/10) |
| utmapp/virglrenderer (`macos-next`) | MIT (`COPYING`, read 2026-11-23) | Neptune additions' per-file headers still to check |
| utmapp/libepoxy (`macos-venus`) | MIT (`COPYING`, read 2026-11-23) | |
| utmapp/WebKit (ANGLE only) | NOASSERTION; ANGLE is BSD-3-Clause | Sparse checkout of `Source/ThirdParty/ANGLE` |
| utmapp/dxmt | **LGPL-2.1-or-later** (`LICENSE`, read 2026-11-23; releases up to v0.80 used an older licence, see `LICENSE.OLD`) | Ship as a separately replaceable dylib with source; the render server already `dlopen`s it by name |
| KhronosGroup/MoltenVK v1.4.2 | Apache-2.0 | |
| HansKristian-Work/vkd3d-proton v3.1 | LGPL-2.1 | Keep as a replaceable dylib |
| utmapp/d3dmetal-native | MIT | Optional; the Apple framework it loads is never bundled |
| stefanberger/swtpm v0.10.2 | BSD-3-Clause (`LICENSE`, read 2026-11-23) | Child process |
| stefanberger/libtpms v0.10.2 | IBM BSD-style for library and TPM 1.2 code (`LICENSE`); TPM 2.0 code terms in the same file still to read | Linked by swtpm |
| osy/kvm-guest-drivers-windows (`neptune`) | BSD-2-Clause | Guest drivers |
| osy/virtio-win-mesa (`neptune`) | none reported; Mesa is MIT | Must be read before bundling |
| osy/build-mesa | none reported | Build scripts only |
| osy/neptune-protocol | Apache-2.0 | Code generator |

## Never bundled

Windows media, product keys, Microsoft tools (DISM, oscdimg, ADK),
Apple's `D3DMetal.framework`, Tiny11 Builder code or binaries (no licence).
