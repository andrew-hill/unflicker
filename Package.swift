// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "unflicker",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "IOUSBLibTransport", targets: ["IOUSBLibTransport"]),
    ],
    targets: [
        .target(name: "CUSBLegacy"),
        .target(name: "UVCCore"),
        .target(name: "AppCore", dependencies: ["UVCCore"]),
        .target(name: "IOUSBLibTransport", dependencies: ["UVCCore", "CUSBLegacy"]),
        .executableTarget(name: "unflicker", dependencies: ["UVCCore"]),
        .testTarget(name: "unflickerTests",
                    dependencies: ["unflicker", "UVCCore", "AppCore", "IOUSBLibTransport"],
                    resources: [.copy("Fixtures")]),
    ]
)
