// swift-tools-version: 6.2
// Spike S3 (throwaway): show QEMU scanout 0 from `-display seemless` in a
// Metal view, send input back over QMP, and measure display latency.
import PackageDescription

let package = Package(
    name: "S3Display",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CMach"),
        .executableTarget(name: "S3Viewer", dependencies: ["CMach"]),
        .executableTarget(name: "S3Latency"),
    ],
    swiftLanguageModes: [.v5]
)
