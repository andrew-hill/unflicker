// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "unflicker",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CUSBLegacy"),
        .executableTarget(name: "unflicker", dependencies: ["CUSBLegacy"]),
        .testTarget(name: "unflickerTests", dependencies: ["unflicker"],
                    resources: [.copy("Fixtures")]),
    ]
)
