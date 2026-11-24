// swift-tools-version: 6.2
//
// SeemlessKit: everything that can be tested without UI (docs/01).
// seemlessctl: headless CLI over SeemlessKit. Every feature lands here first.

import PackageDescription

let package = Package(
    name: "SeemlessKit",
    platforms: [.macOS(.v26)],  // docs/01 D10: macOS 26 and later
    products: [
        .library(name: "SeemlessKit", targets: ["SeemlessKit"]),
        .executable(name: "seemlessctl", targets: ["seemlessctl"]),
    ],
    dependencies: [
        // Apache-2.0. Recorded in THIRD_PARTY.md.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        // Apache-2.0. Runtime for the generated agent protocol types, and the
        // protoc-gen-swift plugin used by scripts/gen-proto.sh.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.41.0"),
    ],
    targets: [
        // Mach plumbing for the display export (docs/04, WP3.1). Our own code:
        // QEMU's side lives only in patches/qemu.
        .target(name: "CSeemlessDisplay"),
        .target(
            name: "SeemlessKit",
            dependencies: ["CSeemlessDisplay", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .executableTarget(
            name: "seemlessctl",
            dependencies: [
                "SeemlessKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SeemlessKitTests",
            dependencies: ["SeemlessKit", "CSeemlessDisplay", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
    ]
)
