// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Everywhere",
    platforms: [
        .macOS(.v13)
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
            dependencies: ["EverywhereCore"]
        ),
        .testTarget(
            name: "EverywhereCoreTests",
            dependencies: ["EverywhereCore"]
        )
    ]
)
