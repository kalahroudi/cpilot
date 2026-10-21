// swift-tools-version:6.0
import PackageDescription

// One dependency, used only for the chat's Markdown and code highlighting: a tested renderer is better than a hand-written one.
let package = Package(
    name: "cpilot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CPilot", targets: ["CPilot"]),
        .executable(name: "cpilot-mcp", targets: ["cpilot-mcp"]),
        .library(name: "CPilotKit", targets: ["CPilotKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "CPilotKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "CPilot", dependencies: ["CPilotKit", .product(name: "Textual", package: "textual")]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "cpilot-mcp", dependencies: ["CPilotKit"]),
        .testTarget(name: "CPilotKitTests", dependencies: ["CPilotKit"]),
    ],
    swiftLanguageModes: [.v5]
)
