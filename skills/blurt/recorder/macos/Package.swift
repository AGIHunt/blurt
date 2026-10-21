// swift-tools-version:5.9
// Blurt.app (macOS). Builds with the Command Line Tools alone: `swift build -c release` (record.py build assembles the
// .app bundle around the `blurt-recorder` executable). Module boundaries: docs/design/desktop-app.md §5 C7.
//
// BLURT_SPARKLE=1 (release builds: scripts/release-mac.sh, CI) links Sparkle 2 for auto-update — a prebuilt
// xcframework from Sparkle's GitHub release, checksum-pinned. Builds from the skill (`record.py build` on the user's
// Mac) leave it out: no network needed, and the skill keeps that app up to date itself.
import Foundation
import PackageDescription

let sparkle = ProcessInfo.processInfo.environment["BLURT_SPARKLE"] == "1"
let sparkleVersion = "2.10.0"   // ≥ 2.9.2 (CVE-2026-47121)
let sparkleChecksum = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"

var targets: [Target] = [
    // Config, paths, ScriptRunner (uv + login-shell env), HotkeyCenter, IndexReader (read-only SQLite), Agents.
    // No AppKit UI here — everything public is what BlurtApp (and tests) may use.
    .target(name: "BlurtCore", path: "Sources/BlurtCore"),
    // The app: Capture/ (recorder, picker, HUD, pen, snap, perch, eggs, note bubble, live audio), App/ (delegate,
    // status menu, agents hub, review window, shortcuts window, updater), MainWindow/ + WebHost/ (WP5), Settings/,
    // Onboarding/, System/ (WP6). main.swift = the launch code.
    .executableTarget(
        name: "BlurtApp",
        dependencies: ["BlurtCore"] + (sparkle ? ["Sparkle"] : []),
        path: "Sources/BlurtApp",
        linkerSettings: sparkle ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
]
// WP5: IndexReader tests + the 20k-row perf budget (`swift test`; needs Xcode's XCTest, `swift build` ignores it)
targets.append(.testTarget(name: "BlurtCoreTests", dependencies: ["BlurtCore"], path: "Tests/BlurtCoreTests"))
if sparkle {
    targets.append(.binaryTarget(
        name: "Sparkle",
        url: "https://github.com/sparkle-project/Sparkle/releases/download/\(sparkleVersion)/Sparkle-for-Swift-Package-Manager.zip",
        checksum: sparkleChecksum))
}

let package = Package(
    name: "Blurt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "blurt-recorder", targets: ["BlurtApp"]),
        .library(name: "BlurtCore", targets: ["BlurtCore"]),
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
