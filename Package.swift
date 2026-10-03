// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [
                .copy("Resources/codex.svg"),
                .copy("Resources/codex.png"),
                .copy("Resources/antigravity.png"),
                // opencode-go's mark (same geometric frame CodexBar uses).
                .copy("Resources/opencodego.png"),
                // DeepSeek's mark from LobeIcons (MIT, see LobeIcons-LICENSE.txt).
                .copy("Resources/deepseek.png"),
                .copy("Resources/LobeIcons-LICENSE.txt"),
                // China's statutory holidays for DeepSeek's off-peak rule, from holiday-cn (MIT).
                // Later years are fetched at runtime; see ChineseHolidaySource.
                .copy("Resources/holiday-cn-2026.json"),
                .copy("Resources/holiday-cn-LICENSE.txt"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeNotchTests",
            dependencies: ["ClaudeNotch"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
