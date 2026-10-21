// swift-tools-version:6.0
import PackageDescription

// No third-party dependencies: keeps the binary small and the memory footprint low.
let package = Package(
    name: "cpilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CPilot", targets: ["CPilot"]),
        .executable(name: "cpilot-mcp", targets: ["cpilot-mcp"]),
        .library(name: "CPilotKit", targets: ["CPilotKit"]),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "CPilotKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "CPilot", dependencies: ["CPilotKit"]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "cpilot-mcp", dependencies: ["CPilotKit"]),
        .testTarget(name: "CPilotKitTests", dependencies: ["CPilotKit"]),
    ],
    swiftLanguageModes: [.v5]
)
