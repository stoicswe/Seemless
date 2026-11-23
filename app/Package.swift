// swift-tools-version: 6.2
//
// Seemless.app (VM manager UI for now; docs/07). All logic lives in
// SeemlessKit; this target is views and glue only. Built into a bundle by
// scripts/build-app.sh. An Xcode project replaces this when the XPC helper
// and entitlements arrive (WP3.3).

import PackageDescription

let package = Package(
    name: "SeemlessApp",
    platforms: [.macOS(.v26)],  // docs/01 D10
    dependencies: [
        .package(path: "../kit"),
    ],
    targets: [
        .executableTarget(
            name: "Seemless",
            dependencies: [.product(name: "SeemlessKit", package: "kit")],
            path: "Seemless"
        ),
    ]
)
