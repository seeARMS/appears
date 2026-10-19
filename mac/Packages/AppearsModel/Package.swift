// swift-tools-version: 6.2
import PackageDescription

// The parts that run EmbeddingGemma 2 on MLX. MLX compiles Metal shaders, which needs
// Xcode, so build this package with xcodebuild (see the README).
//
// Targets:
// - EmbeddingGemma2: a copy of Obscyra-app/EmbeddingGemma2Swift (MIT); licenses in ThirdParty/.
// - GemmaEmbedder: adapts it to AppearsCore's `Embedder`.
// - Lightning: H2O-Lightning-4B (on Qwen3.5-4B), AppearsCore's `Decider`.
// - AppearsCLI: the `appears` command (index, related, eval, stats, mcp).
//
// swift-transformers' Tokenizers module links its Hub downloader, which Appears never
// calls; the engine's sandbox has no network entitlement either way.

let package = Package(
    name: "AppearsModel",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GemmaEmbedder", targets: ["GemmaEmbedder"]),
        .library(name: "Lightning", targets: ["Lightning"]),
        .executable(name: "appears", targets: ["AppearsCLI"]),
    ],
    dependencies: [
        .package(path: "../AppearsKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "EmbeddingGemma2",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "GemmaEmbedder",
            dependencies: ["EmbeddingGemma2", .product(name: "AppearsCore", package: "AppearsKit")]
        ),
        .target(
            name: "Lightning",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "AppearsCore", package: "AppearsKit"),
            ]
        ),
        .executableTarget(
            name: "AppearsCLI",
            dependencies: [
                "GemmaEmbedder",
                "Lightning",
                .product(name: "AppearsCore", package: "AppearsKit"),
                .product(name: "AppearsMCP", package: "AppearsKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GemmaEmbedderTests",
            dependencies: ["GemmaEmbedder", "EmbeddingGemma2", .product(name: "AppearsCore", package: "AppearsKit")],
            resources: [.copy("Resources/reference-vectors.json")]
        ),
        .testTarget(
            name: "LightningTests",
            dependencies: ["Lightning", .product(name: "AppearsCore", package: "AppearsKit")],
            resources: [.copy("Resources/reference-decisions.json")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
