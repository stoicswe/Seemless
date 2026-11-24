#!/bin/bash
# Regenerates the Swift protocol types from proto/seemless.proto (docs/06).
#
#   scripts/gen-proto.sh           write kit/Sources/SeemlessKit/Agent/Generated/
#   scripts/gen-proto.sh --check   fail if the checked-in file is out of date
#
# No protoc needed: protogen (guest/agent/crates/protogen) compiles the
# .proto with protox and runs protoc-gen-swift, which SwiftPM builds from the
# swift-protobuf version pinned in kit/Package.swift. Rust generates its own
# types at build time (guest/agent/crates/proto/build.rs).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cargo="${CARGO:-$HOME/.cargo/bin/cargo}"
out="$root/kit/Sources/SeemlessKit/Agent/Generated"
check=0
[[ "${1:-}" == "--check" ]] && check=1

swift build --package-path "$root/kit" --product protoc-gen-swift -c release >/dev/null
plugin="$(swift build --package-path "$root/kit" --product protoc-gen-swift -c release --show-bin-path)/protoc-gen-swift"
"$cargo" build --quiet --manifest-path "$root/guest/agent/Cargo.toml" -p protogen
protogen="$root/guest/agent/target/debug/protogen"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$protogen" --plugin "$plugin" --proto-dir "$root/proto" --out "$tmp" \
    --param "Visibility=Public,FileNaming=DropPath" seemless.proto >/dev/null

if (( check )); then
    if ! diff -u "$out/seemless.pb.swift" "$tmp/seemless.pb.swift" >/dev/null; then
        echo "kit/Sources/SeemlessKit/Agent/Generated/seemless.pb.swift is out of date; run scripts/gen-proto.sh" >&2
        exit 1
    fi
    echo "generated Swift protocol types are up to date"
else
    mkdir -p "$out"
    cp "$tmp/seemless.pb.swift" "$out/seemless.pb.swift"
    echo "wrote $out/seemless.pb.swift"
fi
