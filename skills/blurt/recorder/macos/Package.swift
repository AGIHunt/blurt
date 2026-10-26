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
    // SwiftTerm v1.20.0, vendored (Vendor/SwiftTerm/README.md): the embedded terminal for agent sessions. Plain source,
    // no plugins or resources, so it builds offline with the Command Line Tools.
    .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources", swiftSettings: [.unsafeFlags(["-suppress-warnings"])]),
    // Config, paths, ScriptRunner (uv + login-shell env), HotkeyCenter, IndexReader (read-only SQLite), Agents.
    // No AppKit UI here — everything public is what BlurtApp (and tests) may use.
    .target(name: "BlurtCore", path: "Sources/BlurtCore"),
    // BlurtTry: catches the Objective-C exceptions AVFoundation raises (Swift can't), so a mic format change never
    // aborts the app.
    .target(name: "BlurtObjC", path: "Sources/BlurtObjC"),
    // The app: Capture/ (recorder, picker, the island and its hanging cards, pen, snap, voice input, note bubble, live
    // audio), App/ (delegate, status menu, agents hub, shortcuts window, updater), MainWindow/ + WebHost/ (the main
    // window and its embedded review), Terminal/ (agent sessions), Settings/, Onboarding/, System/. main.swift = launch.
    .executableTarget(
        name: "BlurtApp",
        dependencies: ["BlurtCore", "BlurtObjC", "SwiftTerm"] + (sparkle ? ["Sparkle"] : []),
        path: "Sources/BlurtApp",
        // K10 string tables: record.py build copies Resources/*.lproj into Contents/Resources (Loc finds them there,
        // or next to the sources for a plain `swift build` run) — not SwiftPM resources.
        exclude: ["Resources"],
        linkerSettings: sparkle ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
]
// WP5: IndexReader tests + the 20k-row perf budget (`swift test`; needs Xcode's XCTest, `swift build` ignores it)
targets.append(.testTarget(name: "BlurtCoreTests", dependencies: ["BlurtCore", "BlurtObjC"], path: "Tests/BlurtCoreTests"))
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
