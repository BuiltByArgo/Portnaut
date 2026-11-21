// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portnaut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Portnaut", targets: ["Portnaut"]),
        .executable(name: "portnaut-doctor", targets: ["PortnautDoctor"])
    ],
    dependencies: [
        // Portnaut's own updates. Pinned: a new Sparkle version is a deliberate change, tested like any other.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "PortnautCore"),
        .executableTarget(
            name: "Portnaut",
            dependencies: ["PortnautCore", .product(name: "Sparkle", package: "Sparkle")],
            // scripts/build.sh copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "PortnautDoctor", dependencies: ["PortnautCore"]),
        .testTarget(name: "PortnautCoreTests", dependencies: ["PortnautCore"])
    ],
    swiftLanguageModes: [.v5]
)
