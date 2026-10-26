// swift-tools-version:6.0
import PackageDescription

// Two dependencies, both because a tested one beats a hand-written one: the chat's Markdown and code highlighting, and the terminal emulator.
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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "CPilotKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "CPilot", dependencies: ["CPilotKit", .product(name: "Textual", package: "textual"), .product(name: "SwiftTerm", package: "SwiftTerm")]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "cpilot-mcp", dependencies: ["CPilotKit"]),
        .testTarget(name: "CPilotKitTests", dependencies: ["CPilotKit"]),
    ],
    swiftLanguageModes: [.v5]
)
