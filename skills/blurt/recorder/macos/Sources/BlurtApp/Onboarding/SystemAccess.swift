// What macOS allows Blurt, read live, and the calls that put Blurt in System Settings' lists (docs/design/dictation.md
// §Permissions). One place for the four permissions and the 🌐-key setting, so the setup assistant, Settings and the
// permission guide agree.
//
//   read       CGPreflightScreenCaptureAccess, AVCaptureDevice.authorizationStatus, AXIsProcessTrusted,
//              CGPreflightListenEventAccess, and com.apple.HIToolbox AppleFnUsageType (read only, never written).
//   register   when the user clicks Allow — never at launch: CGRequestScreenCaptureAccess, AVCaptureDevice.requestAccess,
//              AXIsProcessTrustedWithOptions(prompt), CGRequestListenEventAccess. Each shows macOS's own prompt the
//              first time and adds Blurt to the list, so the user only flips a switch.
//   open       the exact pane (PermissionKind.paneURL).
//
// Test builds (DictationInsert.testMode) never register, never open a pane (unless BLURT_TEST_OPEN_PANES=1) and never
// relaunch; they simulate macOS: BLURT_TEST_SCREEN_RECORDING / BLURT_TEST_INPUT_MONITORING / BLURT_TEST_ACCESSIBILITY
// (1 | 0), BLURT_TEST_MICROPHONE (granted | denied | not_asked), BLURT_TEST_FN_USAGE (0–3 | unset), or the `perm …`
// test hooks. What they would have done is an event ("perm_request", "perm_open_pane", "perm_relaunch").
import AppKit
import AVFoundation
import ApplicationServices
import BlurtCore

enum SystemAccess {
    enum State: String { case granted, denied, notAsked = "not_asked" }

    static var testMode: Bool { DictationInsert.testMode }
    private static let env = ProcessInfo.processInfo.environment

    // MARK: test overrides (test builds only)

    static var testScreen: Bool? = DictationInsert.testMode ? env["BLURT_TEST_SCREEN_RECORDING"].map { $0 == "1" } : nil
    static var testMic: State? = DictationInsert.testMode ? env["BLURT_TEST_MICROPHONE"].flatMap(State.init(rawValue:)) : nil
    /// "unset" = the key isn't there (macOS's default); nil = read the real one
    static var testFnUsage: String? = DictationInsert.testMode ? env["BLURT_TEST_FN_USAGE"] : nil

    // MARK: read

    static func state(_ k: PermissionKind) -> State {
        switch k {
        case .screen:
            let on = testMode && testScreen != nil ? testScreen! : CGPreflightScreenCaptureAccess()
            return on ? .granted : (Config.shared["app.asked_screen"] as? Bool == true ? .denied : .notAsked)
        case .microphone:
            if testMode, let m = testMic { return m }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notAsked
            }
        case .accessibility: return DictationKeys.accessibility ? .granted : .notAsked
        case .inputMonitoring: return DictationKeys.inputMonitoring ? .granted : .notAsked
        case .fnKey: return FnUsage.clashes(fnUsage) ? .notAsked : .granted
        }
    }

    static func granted(_ k: PermissionKind) -> Bool { state(k) == .granted }

    /// System Settings → Keyboard → "Press 🌐 key to" (nil = unset). Synchronized first, so a change made in System
    /// Settings a moment ago is seen.
    static var fnUsage: FnUsage? {
        if testMode, let t = testFnUsage { return FnUsage.from(t) }
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        return FnUsage.from(CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString))
    }

    /// Other dictation apps that also react to Fn, running now (bundle id → name).
    static let fnApps: [String: String] = ["now.typeless.desktop": "Typeless", "com.electron.wispr-flow": "Wispr Flow"]
    static var fnClashApps: [String] {
        if testMode, let t = env["BLURT_TEST_FN_APPS"] { return t.split(separator: ",").map(String.init) }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return fnApps.filter { running.contains($0.key) }.map(\.value).sorted()
    }

    // MARK: register (the user clicked Allow)

    /// Puts Blurt in the pane's list (and shows macOS's own prompt the first time). Returns true when it is granted
    /// already. The microphone asks with macOS's dialog; `done` is called with its answer.
    @discardableResult
    static func register(_ k: PermissionKind, via: String, done: ((Bool) -> Void)? = nil) -> Bool {
        emit(["event": "perm_request", "kind": k.rawValue, "via": via, "test_mode": testMode])
        if testMode { done?(granted(k)); return granted(k) }
        switch k {
        case .screen:
            Config.shared.set("app.asked_screen", true)
            return CGRequestScreenCaptureAccess()
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done?(ok) } }
                return false
            }
            done?(granted(.microphone))
            return granted(.microphone)
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        case .inputMonitoring:
            return Dictation.requestListenAccess(via: via)
        case .fnKey:
            return granted(.fnKey)
        }
    }

    // MARK: open

    static func openPane(_ k: PermissionKind) {
        emit(["event": "perm_open_pane", "kind": k.rawValue, "url": k.paneURL])
        if testMode && env["BLURT_TEST_OPEN_PANES"] != "1" { return }
        if let u = URL(string: k.paneURL) { NSWorkspace.shared.open(u) }
    }

    /// Screen Recording granted while Blurt runs takes effect after a relaunch on some macOS versions: `open -n` our
    /// own bundle once this process has gone, then quit; the new one carries on with the walk (PermissionGuide
    /// resumeIfNeeded). Test builds only say they would (`perm resume` plays the new one's side).
    static func relaunch(resume: [PermissionKind] = [], flow: PermissionFlowKind = .all, source: String = "") {
        let path = Bundle.main.bundlePath
        emit(["event": "perm_relaunch", "bundle": path, "resume": resume.map(\.rawValue), "test_mode": testMode])
        if testMode { return }
        // even with nothing left (Screen Recording is the walk's last step): the relaunched Blurt says it's done and
        // comes back where the walk started
        Config.shared.set("app.permission_resume", ["kinds": resume.map(\.rawValue), "flow": flow.rawValue, "source": source,
                                                    "at": Date().timeIntervalSince1970])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
