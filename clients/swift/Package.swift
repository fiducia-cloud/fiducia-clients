// swift-tools-version:5.7
import PackageDescription

// Fiducia HTTP client — Swift Package Manager manifest.
// Proprietary / UNLICENSED (see README). Distributed by git tag; no central registry.
let package = Package(
    name: "fiducia-client",
    platforms: [
        .macOS(.v12),
        .iOS(.v13),
    ],
    products: [
        .library(name: "Fiducia", targets: ["Fiducia"]),
    ],
    targets: [
        .target(
            name: "Fiducia",
            path: "Sources/Fiducia"
        ),
    ]
)
