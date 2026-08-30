// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DailyUpdate",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DailyUpdate", targets: ["DailyUpdate"])
    ],
    targets: [
        .executableTarget(
            name: "DailyUpdate",
            path: "Sources/DailyUpdate",
            resources: [.process("Resources")]
        )
    ]
)
