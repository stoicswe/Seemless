# proto

The host↔agent Protobuf schema (`seemless.proto`, package `seemless.v1`) is the
single source of truth for Swift and Rust. The contract it implements is in
`docs/06-guest-agent-protocol.md`.

- `seemless.proto`: Envelope and the v1 message catalogue. The compatibility
  rules are at the top of the file.
- `testdata/*.frame`: golden control frames. Rust (`cargo test -p proto`) and
  Swift (`AgentGoldenFrameTests`) must both produce and decode these exact
  bytes. Re-bless them with `SEEMLESS_BLESS=1 ~/.cargo/bin/cargo test
  --manifest-path guest/agent/Cargo.toml -p proto` and review the diff.
- `mock/*.json`: scripts for `seemlessctl mock-agent`.

After editing the schema:

```
scripts/gen-proto.sh                      # Swift types -> kit/Sources/SeemlessKit/Agent/Generated/
~/.cargo/bin/cargo test --manifest-path guest/agent/Cargo.toml -p proto   # Rust regenerates at build time
```

No `protoc` is needed. Rust uses protox (a pure-Rust compiler), and Swift runs
`protoc-gen-swift` through `protogen` (`guest/agent/crates/protogen`).
