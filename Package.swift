// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portnaut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Portnaut", targets: ["Portnaut"]),
        .executable(name: "portnaut-doctor", targets: ["PortnautDoctor"])
    ],
    targets: [
        .target(name: "PortnautCore"),
        .executableTarget(name: "Portnaut", dependencies: ["PortnautCore"]),
        .executableTarget(name: "PortnautDoctor", dependencies: ["PortnautCore"]),
        .testTarget(name: "PortnautCoreTests", dependencies: ["PortnautCore"])
    ],
    swiftLanguageModes: [.v5]
)
