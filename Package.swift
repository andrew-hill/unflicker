// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "unflicker",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "unflicker"),
        .testTarget(name: "unflickerTests", dependencies: ["unflicker"],
                    resources: [.copy("Fixtures")]),
    ]
)
