// swift-tools-version:5.9
// Blurt.app (macOS). Builds with the Command Line Tools alone: `swift build -c release` (record.py build assembles the
// .app bundle around the `blurt-recorder` executable). Module boundaries: docs/design/desktop-app.md §5 C7.
import PackageDescription

let package = Package(
    name: "Blurt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "blurt-recorder", targets: ["BlurtApp"]),
        .library(name: "BlurtCore", targets: ["BlurtCore"]),
    ],
    targets: [
        // Config, paths, ScriptRunner (uv + login-shell env), HotkeyCenter, IndexReader (read-only SQLite), Agents.
        // No AppKit UI here — everything public is what BlurtApp (and tests) may use.
        .target(name: "BlurtCore", path: "Sources/BlurtCore"),
        // The app: Capture/ (recorder, picker, HUD, pen, snap, perch, eggs, note bubble, live audio), App/ (delegate,
        // status menu, agents hub, review window, shortcuts window), MainWindow/ + WebHost/ (WP5), Settings/,
        // Onboarding/, System/ (WP6). main.swift = the launch code.
        .executableTarget(name: "BlurtApp", dependencies: ["BlurtCore"], path: "Sources/BlurtApp"),
        .testTarget(name: "BlurtCoreTests", dependencies: ["BlurtCore"], path: "Tests/BlurtCoreTests"),   // WP5: needs Xcode's XCTest; `swift build` ignores it
    ],
    swiftLanguageVersions: [.v5]
)
