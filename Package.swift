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
        // DuckDuckGo's GRDB distribution: GRDB 7.4.1 compiled with SQLCipher
        // 4.7.0 (encryption at rest, design.md §8). Upstream groue/GRDB.swift
        // has no SPM SQLCipher flavor.
        .package(url: "https://github.com/duckduckgo/GRDB.swift.git", exact: "3.0.0"),
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
            dependencies: ["ShifuCore"],
            // Bundled into Shifu.app by scripts/install-app.sh, not a SwiftPM resource.
            exclude: ["AppIcon.icns"]
        ),
        .testTarget(
            name: "ShifuCoreTests",
            dependencies: ["ShifuCore"]
        ),
    ]
)
