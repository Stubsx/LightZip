// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightZip",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "LightZip", targets: ["LightZip"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "FinderBridge"),
        .target(name: "ArchiveCore"),
        .executableTarget(name: "LightZip", dependencies: ["ArchiveCore", "FinderBridge", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
        .testTarget(name: "FinderBridgeTests", dependencies: ["FinderBridge"])
    ]
)
