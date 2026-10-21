// Settings → General: where recordings go (default ~/Blurt or a bound project's .blurt/), open at login, where review
// pages open, language, what happens after a recording.
import AppKit
import ServiceManagement
import SwiftUI
import BlurtCore

@MainActor
final class GeneralModel: ObservableObject {
    @Published var workspaces: [URL] = []
    @Published var current: URL = defaultWorkspace
    @Published var openAtLogin = false
    @Published var loginError: String?
    @Published var reviewOpenIn = "app"
    @Published var language = "system"
    @Published var processMode = "off"
    @Published var countdown = 3
    @Published var spotlight = true

    init() { reload() }

    func reload() {
        current = currentWorkspace()
        var list = [defaultWorkspace] + knownWorkspaces()
        var seen = Set<String>()
        list = list.filter { seen.insert($0.standardizedFileURL.path).inserted }
        workspaces = list
        openAtLogin = SMAppService.mainApp.status == .enabled
        reviewOpenIn = ((Config.shared["review.open_in"] as? String) ?? "app") == "browser" ? "browser" : "app"
        language = Config.shared["lang"] as? String ?? "system"
        processMode = (recordConfig()["process"] as? String ?? "off") == "off" ? "off" : "auto"
        countdown = recordConfig()["countdown"] as? Int ?? 3
        spotlight = Config.shared["spotlight"] as? Bool ?? true
    }

    func setCurrent(_ u: URL) {
        setRecordConfig("workspace", isDefaultWorkspace(u) ? nil : u.path)
        reload()
    }
    func bindFolder() {
        appDelegate?.mChooseWorkspace()
        reload()
    }
    func forget(_ u: URL) {
        let list = (recordConfig()["workspaces"] as? [String] ?? []).filter { URL(fileURLWithPath: $0).standardizedFileURL != u.standardizedFileURL }
        setRecordConfig("workspaces", list.isEmpty ? nil : list)
        if u.standardizedFileURL == current.standardizedFileURL { setRecordConfig("workspace", nil) }
        reload()
    }
    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
    func setReview(_ v: String) { Config.shared.set("review.open_in", v); reviewOpenIn = v }
    func setLanguage(_ v: String) {
        Config.shared.set("lang", v == "system" ? nil : v)
        language = v
    }
    func setProcess(_ v: String) { setRecordConfig("process", v); processMode = v }
    func setCountdown(_ v: Int) { setRecordConfig("countdown", v); countdown = v }
    func setSpotlight(_ v: Bool) {
        Config.shared.set("spotlight", v ? nil : false)
        spotlight = v
        if v { Spotlight.shared.refresh() } else { Spotlight.shared.removeAll() }
    }

    func gitignoreState(_ ws: URL) -> Bool? {
        guard !isDefaultWorkspace(ws), FileManager.default.fileExists(atPath: ws.appendingPathComponent(".git").path) else { return nil }
        let gi = (try? String(contentsOf: ws.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
        return gi.split(separator: "\n").contains { ["/.blurt", ".blurt", ".blurt/", "/.blurt/"].contains($0.trimmingCharacters(in: .whitespaces)) }
    }
    func addGitignore(_ ws: URL) {
        let f = ws.appendingPathComponent(".gitignore")
        var gi = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        if !gi.isEmpty && !gi.hasSuffix("\n") { gi += "\n" }
        gi += "# Blurt recordings (screen + voice) — local only\n.blurt/\n"
        try? gi.write(to: f, atomically: true, encoding: .utf8)
        objectWillChange.send()
    }
}

struct GeneralPane: View {
    @StateObject var m = GeneralModel()

    var body: some View {
        PaneFrame {
            Section {
                Picker(L("当前工作区", "Record into"), selection: Binding(get: { m.current.standardizedFileURL }, set: { m.setCurrent($0) })) {
                    ForEach(m.workspaces, id: \.self) { w in
                        Text(isDefaultWorkspace(w) ? L("默认（~/Blurt）", "Default (~/Blurt)") : w.lastPathComponent)
                            .tag(w.standardizedFileURL)
                    }
                }
                ForEach(m.workspaces.filter { !isDefaultWorkspace($0) }, id: \.self) { w in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.lastPathComponent)
                            Text((w.path as NSString).abbreviatingWithTildeInPath + "/.blurt/sessions").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let ok = m.gitignoreState(w) {
                            if ok { Label(".gitignore", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
                            else { Button(L("加入 .gitignore", "Add to .gitignore")) { m.addGitignore(w) }.help(L("录屏留在本地，不进仓库", "Keep recordings out of the repo")) }
                        }
                        Button { NSWorkspace.shared.open(w) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless)
                            .help(L("在访达中打开", "Open in Finder"))
                        Button { m.forget(w) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .help(L("从列表移除（不删文件）", "Remove from the list (files stay)"))
                    }
                }
                HStack {
                    Button(L("绑定项目文件夹…", "Bind a project folder…")) { m.bindFolder() }
                    Spacer()
                    Button(L("打开 ~/Blurt", "Open ~/Blurt")) { NSWorkspace.shared.open(defaultWorkspace) }
                }
                Hint(L("绑定的项目把录屏放在 <项目>/.blurt/sessions，agent 修 bug 时能直接对照代码。",
                       "A bound project keeps recordings in <project>/.blurt/sessions, next to the code your agent will fix."))
            } header: { Text(L("工作区", "Workspaces")) }

            Section {
                Toggle(L("登录时打开口喷鸡", "Open Blurt at login"), isOn: Binding(get: { m.openAtLogin }, set: { m.setLogin($0) }))
                if let e = m.loginError { Text(e).font(.caption).foregroundStyle(.orange) }
                Picker(L("审核页打开在", "Open review pages in"), selection: Binding(get: { m.reviewOpenIn }, set: { m.setReview($0) })) {
                    Text(L("口喷鸡窗口", "A Blurt window")).tag("app")
                    Text(L("浏览器", "The browser")).tag("browser")
                }
                Picker(L("语言", "Language"), selection: Binding(get: { m.language }, set: { m.setLanguage($0) })) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                if (m.language == "system" ? nil : m.language) != nil && m.language != opts.lang {
                    Hint(L("重新打开口喷鸡后生效；整理出的条目也用这个语言。", "Takes effect when Blurt restarts; items are written in this language too."))
                }
                Toggle(L("在 Spotlight 里搜得到条目", "Show items in Spotlight"), isOn: Binding(get: { m.spotlight }, set: { m.setSpotlight($0) }))
            } header: { Text(L("应用", "App")) }

            Section {
                Picker(L("录完之后", "After a recording"), selection: Binding(get: { m.processMode }, set: { m.setProcess($0) })) {
                    Text(L("只保存", "Just save it")).tag("off")
                    Text(L("交给 agent 后台整理", "Process it with an agent")).tag("auto")
                }
                Picker(L("开始前倒计时", "Countdown"), selection: Binding(get: { m.countdown }, set: { m.setCountdown($0) })) {
                    Text(L("不倒计时", "None")).tag(0)
                    Text(L("3 秒", "3 s")).tag(3)
                    Text(L("5 秒", "5 s")).tag(5)
                }
                HStack {
                    Spacer()
                    Button(L("重新运行设置助手…", "Run the setup assistant again…")) { Onboarding.shared.show() }
                }
            } header: { Text(L("录制", "Recording")) }
        }
        .onAppear { m.reload() }
    }
}
