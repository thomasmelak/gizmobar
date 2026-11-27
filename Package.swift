// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gizmobar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gizmobar", targets: ["Gizmobar"]),
        .executable(name: "gizmo", targets: ["gizmo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.2.2"),
    ],
    targets: [
        // Platform-neutral model: events, bus, config, theme, icon resolution.
        .target(
            name: "GizmoCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
        // Unix socket protocol shared by the app and the `gizmo` CLI.
        .target(name: "GizmoIPC", dependencies: ["GizmoCore"]),
        // In-process data sources (AeroSpace, apps, clock, displays).
        .target(
            name: "GizmoProviders",
            dependencies: ["GizmoCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Network"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // TypeScript plugins: one JavaScriptCore context per plugin.
        .target(
            name: "GizmoPlugins",
            dependencies: ["GizmoCore"],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        // 3D scene engine (RealityKit models) and the Metal audio visualizer.
        .target(
            name: "GizmoScene",
            dependencies: ["GizmoCore"],
            linkerSettings: [
                .linkedFramework("RealityKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // Panels, SwiftUI widgets, icon rendering.
        .target(name: "GizmoUI", dependencies: ["GizmoCore", "GizmoProviders", "GizmoScene"]),
        .executableTarget(
            name: "Gizmobar",
            dependencies: ["GizmoCore", "GizmoIPC", "GizmoProviders", "GizmoPlugins", "GizmoUI"]
        ),
        .executableTarget(name: "gizmo", dependencies: ["GizmoCore", "GizmoIPC"]),
        .testTarget(name: "GizmoCoreTests", dependencies: ["GizmoCore", "GizmoProviders"]),
        .testTarget(name: "GizmoPluginsTests", dependencies: ["GizmoCore", "GizmoPlugins"]),
        .testTarget(name: "GizmoSceneTests", dependencies: ["GizmoCore", "GizmoScene"]),
    ]
)
