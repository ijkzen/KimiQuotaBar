// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KimiQuotaBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "KimiQuotaBar",
            targets: ["KimiQuotaBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "KimiQuotaBar",
            path: ".",
            exclude: ["Makefile", "README.md", "AGENTS.md", ".github", "docs", "assets"],
            sources: [
                "KimiQuotaBarApp.swift",
                "QuotaManager.swift",
                "OpenCodeGoManager.swift",
                "LaunchAtLoginManager.swift"
            ]
        )
    ]
)