// swift-tools-version: 6.2
import PackageDescription

// AppearsKit holds everything that doesn't need a window or the model. It builds and tests
// with the Command Line Tools alone (`swift test`).
//
// - AppearsCore: the index (files, Notes, Messages, extractors, vectors, full text), ranking, the
//   journal, and the messages the app and the engine exchange. Runs in the sandboxed engine.
// - AppearsContext: reading what's on screen through the Accessibility API, browser URLs,
//   exclusions and the OCR fallback. Runs in the (unsandboxed) app.
// - AppearsMCP: `appears mcp`, a Model Context Protocol server over stdio that lets local
//   agents search the index. Runs in the CLI, never in the app or the engine.
//
// AppearsCore and AppearsContext have no networking code. AppearsDownloads is linked
// ONLY into the sandboxed model downloader, never the app or the engine.

let package = Package(
    name: "AppearsKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppearsCore", targets: ["AppearsCore"]),
        .library(name: "AppearsContext", targets: ["AppearsContext"]),
        .library(name: "AppearsMCP", targets: ["AppearsMCP"]),
        .library(name: "AppearsDownloads", targets: ["AppearsDownloads"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AppearsCore",
            dependencies: ["AppearsMessages", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/model-download.json")]
        ),
        .target(name: "AppearsMessages", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(
            name: "AppearsDownloads",
            dependencies: ["AppearsCore"]
        ),
        .target(
            name: "AppearsContext",
            dependencies: ["AppearsCore", "AppearsMessages"]
        ),
        .target(
            name: "AppearsMCP",
            dependencies: ["AppearsCore"]
        ),
        .testTarget(
            name: "AppearsCoreTests",
            dependencies: ["AppearsCore", "AppearsMessages", "AppearsDownloads", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AppearsMCPTests",
            dependencies: ["AppearsMCP", "AppearsCore"]
        ),
        .testTarget(
            name: "AppearsContextTests",
            dependencies: ["AppearsContext", "AppearsCore", "AppearsMessages"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
