// The permission guide (docs/design/dictation.md §Permissions): one "Set up permissions" walk through what's missing,
// used by the setup assistant, Settings → Privacy, Settings → Dictation ("Turn On…"), the menu-bar "Turn On
// Dictation…" row, the island's reminder, and Screen Recording the first time a snap or a recording needs it (the
// toast's Allow…, the recording's alert). For each step, in order (BlurtCore PermissionPlan):
//   1. register Blurt in the list (SystemAccess.register: macOS's own prompt the first time), so the user only flips
//      a switch; the microphone just asks with macOS's dialog;
//   2. open the exact pane;
//   3. show the helper panel (HelperPanel.swift) docked under the System Settings window's list (beside the window
//      when there's no room below): the Blurt tile to drag into the list, one line ("Turn on Blurt in the list"), why
//      it's needed, every step's state live;
//   4. poll every 0.25 s; when the step is satisfied, the next one (after the last: the done line, then the panel
//      closes by itself). Input Monitoring or Accessibility arriving makes dictation's listener again at once (the tap
//      made before the grant only hears Blurt).
// At the end the panel closes, Blurt comes back to the front where the walk started, with a check mark: "Done —
// dictation works in every app now." — only once a speech model is there too; before that: "Permissions are set.
// Next, the speech model — then Fn dictates anywhere." Nothing in System Settings is ever clicked or changed by Blurt.
// The step count ("1 of 2") is the walk's live list. With Fn as the key, Input Monitoring isn't planned while
// Accessibility is still to come (the Fn filter hears the key with Accessibility alone), so the count doesn't promise
// a step and then drop it; only if the filter still can't hear the key once Accessibility is on does it join the walk —
// so until Accessibility is on the panel names the step without a total (`mayGrow`): a count never grows mid-walk. A
// row's Allow (`only`) is judged on its own kinds when it ends ("Screen Recording is on", not "Done for now"); Screen
// Recording turned on while Blurt runs ends with macOS's relaunch line and Restart Blurt.
// Re-add (`reauthorize`, v0.9): macOS lists Blurt as allowed but ScreenCaptureKit refuses — the grant was made for an
// older build (ScreenHelp, BlurtCore ScreenGrant.stale). The Screen Recording step then isn't satisfied by the switch
// being on: the panel says to remove Blurt with − and add it again, and Restart Blurt is what finishes it.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class PermissionGuide: ObservableObject {
    static let shared = PermissionGuide()

    enum Source: String { case onboarding, privacy, dictation, menu, island, page, capture, test, general }

    @Published private(set) var running = false
    @Published private(set) var flow: PermissionFlowKind = .all
    /// the walk, fixed when it starts (each shown with its live state)
    @Published private(set) var steps: [PermissionKind] = []
    @Published private(set) var current: PermissionKind?
    @Published private(set) var satisfiedNow: Set<PermissionKind> = []
    /// the current step was just satisfied: the panel shows its check for a moment
    @Published private(set) var stepDone = false
    /// the walk ended with everything done: the check-mark line the assistant / Settings show — a short headline
    /// ("Permissions are set"), and what comes next, if anything, as a quieter line under it (`finishedDetail`)
    @Published private(set) var finished: String?
    @Published private(set) var finishedDetail: String?
    /// the walk turned Screen Recording on while Blurt runs: macOS applies it after a relaunch — the done line says so
    /// and has Restart Blurt
    @Published private(set) var finishedRestart = false
    /// the panel's side of the System Settings window (its notch points that way): under its list, or beside it
    @Published var dock: HelperDock.Side = .free
    /// the panel's card width: the list's width under it, a fixed one beside it (HelperDock.dock)
    @Published var cardWidth: CGFloat = HelperDock.sideWidth
    /// System Settings has no window on screen (the panel offers to open the pane again)
    @Published var noWindow = false
    /// Screen Recording's step has waited a while: maybe macOS wants Blurt restarted
    @Published private(set) var suggestRestart = false
    /// the re-add form: Screen Recording is on in the list but doesn't work (a stale grant)
    @Published private(set) var reauthorize = false

    private(set) var source: Source = .test
    /// the walk was asked for these kinds only (a row's Allow): it never grows
    private var only: [PermissionKind]?
    private var timer: Timer?
    private var stepStarted = Date()
    private var finishedAt = Date.distantPast
    private var lastAX = false
    private var lastIM = false

    // MARK: what counts as done

    /// Input Monitoring is satisfied once the key is heard by a tap (the Fn filter needs only Accessibility) — and,
    /// with Fn as the key, while Accessibility is still to come (that filter is what will hear it: not a step to
    /// promise); the 🌐 key once Fn isn't the key, dictation is off, or macOS does nothing on Fn.
    func satisfied(_ k: PermissionKind) -> Bool {
        switch k {
        case .inputMonitoring:
            let fnFilter = Dictation.enabled && Dictation.key == .fn
            return SystemAccess.granted(.inputMonitoring)
                || (fnFilter && (Dictation.shared.listenerKind == .tap || !SystemAccess.granted(.accessibility)))
        case .fnKey:
            return !Dictation.enabled || Dictation.key != .fn || SystemAccess.granted(.fnKey)
        case .screen where reauthorize:
            return false                // the switch is on already: only a relaunch after re-adding Blurt tells
        default:
            return SystemAccess.granted(k)
        }
    }

    private var satisfiedSet: Set<PermissionKind> { Set(PermissionKind.allCases.filter(satisfied)) }

    /// What a walk of `flow` would ask for now (Settings shows "Set up permissions" only when this isn't empty).
    func missing(_ flow: PermissionFlowKind) -> [PermissionKind] { PermissionPlan.steps(flow, satisfied: satisfiedSet) }

    // MARK: walk

    /// Starts a walk (or restarts it: a click elsewhere while one runs). `only` = just these kinds (a row's Allow).
    func start(_ flow: PermissionFlowKind, only: [PermissionKind]? = nil, source: Source, reauthorize: Bool = false) {
        self.flow = flow
        self.source = source
        self.only = only
        self.reauthorize = reauthorize && (only ?? []).contains(.screen)
        finished = nil
        finishedDetail = nil
        finishedRestart = false
        let walk = PermissionPlan.steps(flow, only: only, satisfied: satisfiedSet)
        emit(["event": "perm_guide", "op": "start", "flow": flow.rawValue, "source": source.rawValue, "steps": walk.map(\.rawValue),
              "reauthorize": self.reauthorize])
        guard !walk.isEmpty else {
            steps = []
            return finish(already: true)
        }
        steps = walk
        running = true
        satisfiedNow = satisfiedSet
        lastAX = SystemAccess.granted(.accessibility)
        lastIM = SystemAccess.granted(.inputMonitoring)
        go(walk[0])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func go(_ k: PermissionKind) {
        current = k
        stepDone = false
        suggestRestart = false
        stepStarted = Date()
        emit(["event": "perm_guide", "op": "step", "kind": k.rawValue, "index": steps.firstIndex(of: k) ?? -1, "of": steps.count])
        switch k {
        case .microphone where SystemAccess.state(.microphone) == .notAsked:
            // macOS's own dialog asks; nothing to find in System Settings
            SystemAccess.register(.microphone, via: "guide") { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
            HelperPanel.shared.show()
        case .fnKey:
            SystemAccess.openPane(.fnKey)
            HelperPanel.shared.show()
        case .screen where reauthorize:
            // macOS has Blurt in the list already: the pane, and the panel saying to remove it and add it again
            suggestRestart = true
            SystemAccess.openPane(.screen)
            HelperPanel.shared.show()
        default:
            if SystemAccess.register(k, via: "guide") { return poll() }
            // the pane after macOS's prompt has had a moment to appear (it lists Blurt as it does)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard self?.current == k, self?.running == true else { return }
                SystemAccess.openPane(k)
            }
            HelperPanel.shared.show()
        }
    }

    /// Every 0.25 s while a walk runs: the states, and the next step once this one is satisfied.
    func poll() {
        guard running, let k = current else { return }
        let ax = SystemAccess.granted(.accessibility), im = SystemAccess.granted(.inputMonitoring)
        if ax != lastAX || im != lastIM {
            // the listener depends on both: make it again now rather than at its next 3 s poll
            lastAX = ax
            lastIM = im
            Dictation.shared.refreshListener(via: "guide")
        }
        let after = satisfiedSet
        if after != satisfiedNow { satisfiedNow = after }
        if k == .screen && !suggestRestart && Date().timeIntervalSince(stepStarted) > 12 { suggestRestart = true }
        guard after.contains(k), !stepDone else { return }
        stepDone = true
        emit(["event": "perm_guide", "op": "granted", "kind": k.rawValue])
        // a step with more to come shows its check for a moment, then the next one opens; the last one goes straight
        // to the done line, and the panel closes by itself after it (HelperPanel.doneFor)
        let last = upcoming().rest.isEmpty
        DispatchQueue.main.asyncAfter(deadline: .now() + (last ? 0 : 0.8)) { [weak self] in
            MainActor.assumeIsolated { self?.next() }
        }
    }

    /// The walk may still gain a step: Input Monitoring, with Fn as the key, while Accessibility is still to come (only
    /// once it is on does it tell whether the Fn filter hears the key). The panel then names the step without a total
    /// ("Accessibility", not "1 of 2" that turns into "2 of 3").
    var mayGrow: Bool {
        guard running, only == nil, !steps.contains(.inputMonitoring), Dictation.enabled, Dictation.key == .fn,
              !SystemAccess.granted(.inputMonitoring), !SystemAccess.granted(.accessibility) else { return false }
        return PermissionPlan.steps(flow, satisfied: []).contains(.inputMonitoring)
    }

    /// The steps done so far (the current one included) and the ones still to come.
    private func upcoming() -> (done: [PermissionKind], rest: [PermissionKind]) {
        let done = Array(steps.prefix { $0 != current } + (current.map { [$0] } ?? []))
        var rest = Array(steps.drop { $0 != current }.dropFirst().filter { !satisfied($0) })
        // what the walk didn't plan but now needs (Input Monitoring when the Fn filter still can't hear the key with
        // Accessibility on) joins it, in the plan's order
        if only == nil {
            let planned = PermissionPlan.steps(flow, satisfied: satisfiedSet)
            for k in planned where !done.contains(k) && !rest.contains(k) {
                rest.insert(k, at: rest.firstIndex { a in (planned.firstIndex(of: a) ?? 0) > (planned.firstIndex(of: k) ?? 0) } ?? rest.endIndex)
            }
        }
        return (done, rest)
    }

    private func next() {
        guard running else { return }
        let (done, rest) = upcoming()
        steps = done + rest           // what got satisfied on the way leaves the count ("2 of 2", not "2 of 3")
        if let n = rest.first { go(n) } else { finish(already: false) }
    }

    /// The panel's Skip: this step stays as it is, on to the next.
    func skip() {
        guard running, let k = current else { return }
        emit(["event": "perm_guide", "op": "skip", "kind": k.rawValue])
        stepDone = true
        next()
    }

    /// The panel's close button: the walk stops where it is.
    func cancel() {
        guard running else { return }
        emit(["event": "perm_guide", "op": "cancel", "kind": current?.rawValue ?? NSNull()])
        stop()
        HelperPanel.shared.hide()
    }

    /// The pane again (the user closed System Settings, or it went behind).
    func reopenPane() { if let k = current { SystemAccess.openPane(k) } }

    /// Screen Recording: relaunch, and carry on with the rest of the walk afterwards.
    func restartForScreen() {
        let rest = Array(steps.drop { $0 != current }.dropFirst())
        SystemAccess.relaunch(resume: rest, flow: flow, source: source.rawValue)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        running = false
        reauthorize = false
        current = nil
        stepDone = false
    }

    private func finish(already: Bool) {
        stop()
        // what was asked for: a row's Allow is judged on its own kinds, not on the whole flow ("Done for now" after
        // the user did exactly what they set out to)
        let everything = PermissionPlan.steps(flow, only: only, satisfied: satisfiedSet).isEmpty
        let heard = Dictation.enabled && Dictation.shared.tapInstalled
        // "dictation works in every app" only when it does: the key is heard and a speech model is there
        let model = DictationModels.shared.dictationReady != false
        let dictationWorks = heard && model
        let aboutDictation = flow == .dictation || source == .menu || source == .island
        // Screen Recording turned on while Blurt runs: it applies after a relaunch (as Settings → Privacy's row says)
        let restart = (only ?? PermissionPlan.steps(flow, satisfied: [])).contains(.screen) && SystemAccess.screenAskedThisRun
            && satisfied(.screen)
        let rowKinds = only.map { ListFormatter.localizedString(byJoining: $0.map(PermissionGuide.name)) }
        let (msg, detail): (String, String?) = {
            if aboutDictation && dictationWorks { return (T("settings.perm.done.dictation"), nil) }
            if aboutDictation && heard { return (T("settings.perm.done.no_model.title"), T("settings.perm.done.no_model", Dictation.keyInline)) }
            guard everything else { return (T("settings.perm.done.some.title"), T("settings.perm.done.some")) }
            if restart {
                return (T("settings.perm.step_done", rowKinds ?? PermissionGuide.name(.screen)), T("settings.privacy.macos_applies_screen_recording"))
            }
            if let r = rowKinds { return (T("settings.perm.step_done", r), nil) }
            return (T("settings.perm.done.all"), nil)
        }()
        finished = msg
        finishedDetail = detail
        finishedRestart = everything && restart
        finishedAt = Date()
        emit(["event": "perm_guide", "op": "done", "already": already, "message": msg, "detail": detail ?? NSNull(), "restart": finishedRestart,
              "dictation_works": dictationWorks, "model": model,
              "missing": PermissionPlan.steps(flow, satisfied: satisfiedSet).map(\.rawValue)])
        HelperPanel.shared.showDone(msg, after: already ? 0 : 0.2)
        bringBack()
        let at = finishedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                if self?.finishedAt == at { self?.finished = nil; self?.finishedDetail = nil; self?.finishedRestart = false }
            }
        }
    }

    /// Blurt to the front, where the walk started.
    private func bringBack() {
        // a snap / recording asked: no window to come back to (the user snaps again where they were)
        guard source != .capture else { return }
        activateApp()
        switch source {
        case .onboarding: Onboarding.shared.bringToFront()
        case .privacy: AppEnvironment.settings?.show(pane: "privacy")
        case .general: AppEnvironment.settings?.show(pane: "general/general.card_drag")   // Settings → General's drag choice
        case .dictation, .menu, .island, .page: AppEnvironment.settings?.show(pane: "dictation")
        case .capture, .test: break
        }
    }

    /// After a relaunch for Screen Recording (config app.permission_resume, < 10 min old): carry on.
    func resumeIfNeeded() {
        guard let r = Config.shared["app.permission_resume"] as? [String: Any] else { return }
        Config.shared.set("app.permission_resume", nil)
        guard let at = r["at"] as? Double, Date().timeIntervalSince1970 - at < 600 else { return }
        let kinds = (r["kinds"] as? [String] ?? []).compactMap(PermissionKind.init(rawValue:))
        let flow = PermissionFlowKind(rawValue: r["flow"] as? String ?? "") ?? .all
        let src = Source(rawValue: r["source"] as? String ?? "") ?? .privacy
        emit(["event": "perm_guide", "op": "resume", "steps": kinds.map(\.rawValue), "source": src.rawValue])
        if kinds.isEmpty {
            // Screen Recording was the walk's last step: the done line, back where the walk started
            self.flow = flow
            self.source = src
            return finish(already: true)
        }
        start(flow, only: kinds, source: src)
    }

    // MARK: words

    static func name(_ k: PermissionKind) -> String { T("settings.perm.\(k.rawValue)") }
    static func why(_ k: PermissionKind) -> String {
        if k == .screen, shared.reauthorize { return T("settings.perm.screen.readd_why") }
        return k == .inputMonitoring || k == .fnKey ? T("settings.perm.\(k.rawValue).why", Dictation.keyInline) : T("settings.perm.\(k.rawValue).why")
    }
    /// The panel's one line for the current step.
    func headline(_ k: PermissionKind) -> String {
        if stepDone { return T("settings.perm.step_done", PermissionGuide.name(k)) }
        switch k {
        case .microphone where SystemAccess.state(.microphone) == .notAsked: return T("onboarding.guide.mic_prompt")
        case .screen where reauthorize: return T("settings.perm.screen.readd")
        case .fnKey: return T("onboarding.guide.fn_headline")
        default: return T("onboarding.guide.turn_on")
        }
    }

    /// The panel's line under the headline: why, in one short clause (Settings' rows say it at length). For the
    /// microphone's dialog: where that dialog is.
    func guideWhy(_ k: PermissionKind) -> String {
        if k == .screen, reauthorize { return T("settings.perm.screen.readd_why") }
        switch k {
        case .microphone: return SystemAccess.state(.microphone) == .notAsked ? T("onboarding.guide.mic_where") : T("onboarding.guide.why.microphone")
        case .accessibility: return T("onboarding.guide.why.accessibility")
        case .inputMonitoring: return T("onboarding.guide.why.input_monitoring", Dictation.keyInline)
        case .screen: return T("onboarding.guide.why.screen")
        case .fnKey: return T("onboarding.guide.why.fn_key")
        }
    }
}

/// The check-mark line after a walk ("Done — dictation works in every app now."), for the assistant and Settings.
struct PermissionDoneBanner: View {
    @ObservedObject var g = PermissionGuide.shared
    var body: some View {
        if let f = g.finished {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(nsImage: BlurtIcon.check.symbolImage(pointSize: 13, weight: .semibold)).foregroundStyle(Color.brandOk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f).fixedSize(horizontal: false, vertical: true)
                    if let d = g.finishedDetail {
                        Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if g.finishedRestart { Button(T("settings.perm.restart")) { SystemAccess.relaunch() } }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }
}
