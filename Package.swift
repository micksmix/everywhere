// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Everywhere",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3")
    ],
    targets: [
        .target(
            name: "EverywhereCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Everywhere",
            dependencies: ["EverywhereCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "EverywhereCoreTests",
            dependencies: ["EverywhereCore"]
        )
    ]
)
