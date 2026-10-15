// swift-tools-version: 6.2
import PackageDescription

// AppearsKit holds everything that doesn't need a window or the model. It builds and tests
// with the Command Line Tools alone (`swift test`).
//
// - AppearsCore: the index (files, Notes, extractors, vectors, full text), ranking, the
//   journal, and the messages the app and the engine exchange. Runs in the sandboxed engine.
// - AppearsContext: reading what's on screen through the Accessibility API, browser URLs,
//   exclusions and the OCR fallback. Runs in the (unsandboxed) app.
//
// Privacy rule for every target here: no networking code.

let package = Package(
    name: "AppearsKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppearsCore", targets: ["AppearsCore"]),
        .library(name: "AppearsContext", targets: ["AppearsContext"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AppearsCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "AppearsContext",
            dependencies: ["AppearsCore"]
        ),
        .testTarget(
            name: "AppearsCoreTests",
            dependencies: ["AppearsCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
