// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "unflicker",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CUSBLegacy"),
        .target(name: "UVCCore"),
        .target(name: "IOUSBLibTransport", dependencies: ["UVCCore", "CUSBLegacy"]),
        .executableTarget(name: "unflicker", dependencies: ["UVCCore"]),
        .testTarget(name: "unflickerTests",
                    dependencies: ["unflicker", "UVCCore", "IOUSBLibTransport"],
                    resources: [.copy("Fixtures")]),
    ]
)
