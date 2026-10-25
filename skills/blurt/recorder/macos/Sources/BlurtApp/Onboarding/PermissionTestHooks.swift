// The permission guide's test hooks (BLURT_TEST_COMMANDS=1, the `perm …` command of SnapApp.swift's channel). They
// simulate what macOS says — nothing is granted, revoked, registered or reset, and no System Settings pane is opened
// unless BLURT_TEST_OPEN_PANES=1 — and drive the guide the way its buttons do.
//   perm screen on|off|clear · perm mic granted|denied|not_asked|clear · perm ax on|off|clear · perm im on|off|clear
//   perm fn 0|1|2|3|unset|clear (AppleFnUsageType) · perm fnapps Typeless,…|clear (other Fn apps running)
//   perm guide all|dictation [KIND,…] [SOURCE] · perm skip · perm cancel · perm restart · perm poll
//   perm resume KIND,…|- FLOW SOURCE (what a relaunch for Screen Recording leaves behind, then the launch's resume)
//   perm standin show [x,y,w,h] | move x,y | hide | off (a window of ours standing in for System Settings)
//   perm drag PASTEBOARD (what dragging the Blurt tile carries) · perm status
import AppKit
import BlurtCore

extension App {
    func permCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        let v = a.count > 1 ? a[1] : ""
        MainActor.assumeIsolated {
            let g = PermissionGuide.shared
            switch a.first ?? "status" {
            case "screen": SystemAccess.testScreen = v == "clear" ? nil : v == "on"
            case "mic": SystemAccess.testMic = v == "clear" ? nil : SystemAccess.State(rawValue: v)
            case "ax": DictationKeys.testAccessibility = v == "clear" ? nil : v == "on"
            case "im": DictationKeys.testInputMonitoring = v == "clear" ? nil : v == "on"
            case "fn": SystemAccess.testFnUsage = v == "clear" ? nil : v
            case "fnapps": setenv("BLURT_TEST_FN_APPS", v == "clear" ? "" : v, 1)
            case "guide":
                let flow = PermissionFlowKind(rawValue: v) ?? .all
                let only = a.count > 2 && a[2] != "-" ? a[2].split(separator: ",").compactMap { PermissionKind(rawValue: String($0)) } : nil
                let src = a.count > 3 ? PermissionGuide.Source(rawValue: a[3]) ?? .test : .test
                g.start(flow, only: only, source: src)
            case "skip": g.skip()
            case "cancel": g.cancel()
            case "restart": g.restartForScreen()
            case "resume":
                let kinds = v == "-" ? [] : v.split(separator: ",").map(String.init)
                Config.shared.set("app.permission_resume", ["kinds": kinds, "flow": a.count > 2 ? a[2] : "all",
                                                            "source": a.count > 3 ? a[3] : "privacy", "at": Date().timeIntervalSince1970])
                g.resumeIfNeeded()
            case "poll": g.poll()
            case "standin":
                HelperPanel.StandIn.command(a.dropFirst().joined(separator: " "))
                HelperPanel.shared.reposition(animated: false)
            case "drag":
                let pb = NSPasteboard(name: .init(v.isEmpty ? "blurt-test-perm-drag" : v))
                pb.clearContents()
                pb.writeObjects([AppTileView.pasteboardWriter()])
                emit(["event": "perm_drag_pasteboard", "types": (pb.types ?? []).map(\.rawValue),
                      "url": pb.string(forType: .fileURL) ?? NSNull(), "bundle": Bundle.main.bundleURL.absoluteString])
                pb.releaseGlobally()
                return
            default: break
            }
            if g.running { g.poll() }
            let f = HelperPanel.shared.frame.map(toCG)
            let t = HelperPanel.targetFrame()
            emit(["event": "perm_status",
                  "states": Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0.rawValue, SystemAccess.state($0).rawValue) }),
                  "satisfied": PermissionKind.allCases.filter(g.satisfied).map(\.rawValue),
                  "fn_usage": SystemAccess.fnUsage?.rawValue ?? NSNull(), "fn_apps": SystemAccess.fnClashApps,
                  "running": g.running, "flow": g.flow.rawValue, "steps": g.steps.map(\.rawValue), "current": g.current?.rawValue ?? NSNull(),
                  "finished": g.finished ?? NSNull(), "finished_detail": g.finishedDetail ?? NSNull(), "dock": g.dock.rawValue, "no_window": g.noWindow,
                  "panel": HelperPanel.shared.isShown, "panel_window": HelperPanel.shared.windowNumber ?? -1,
                  "panel_frame": f.map { [$0.minX, $0.minY, $0.width, $0.height].map { Double(Int($0)) } } ?? NSNull(),
                  "target": t.map { [$0.minX, $0.minY, $0.width, $0.height].map { Double(Int($0)) } } ?? NSNull(),
                  "listener": Dictation.shared.listenerKind.rawValue, "filter": Dictation.shared.fnFiltering,
                  "tap_generation": Dictation.shared.tapGeneration, "key": Dictation.key.rawValue, "mode": Dictation.mode.rawValue])
        }
    }
}
