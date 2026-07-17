// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shifu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShifuCore", targets: ["ShifuCore"]),
        .executable(name: "shifud", targets: ["shifud"]),
        .executable(name: "shifu-analyzer", targets: ["shifu-analyzer"]),
        .executable(name: "shifu", targets: ["shifu-cli"]),
        .executable(name: "ShifuApp", targets: ["ShifuApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Models, DB access, capture ladder logic, sessionizer, classifier, FSRS.
        // Everything testable lives here.
        .target(
            name: "ShifuCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Capture daemon. LaunchAgent, headless, no network (design.md §8).
        .executableTarget(
            name: "shifud",
            dependencies: ["ShifuCore"]
        ),
        // Batch analysis worker. The only binary allowed to touch the network.
        .executableTarget(
            name: "shifu-analyzer",
            dependencies: ["ShifuCore"]
        ),
        // CLI: log, review, pause, status.
        .executableTarget(
            name: "shifu-cli",
            dependencies: ["ShifuCore"]
        ),
        // Menu bar app + dashboard (SwiftUI).
        .executableTarget(
            name: "ShifuApp",
            dependencies: ["ShifuCore"]
        ),
        .testTarget(
            name: "ShifuCoreTests",
            dependencies: ["ShifuCore"]
        ),
    ]
)
