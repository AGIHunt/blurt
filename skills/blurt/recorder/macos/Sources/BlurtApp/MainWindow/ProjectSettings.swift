// Project settings (K2), a sheet on the main window: name, key (the item id prefix), description (what the AI reads
// when it sorts captures into projects), the default agent, and whether hand-offs get their own git worktree.
// Saved with projects.py set; the registry is never written here.
import AppKit
import BlurtCore

final class ProjectSettingsSheet: NSObject, NSTextFieldDelegate {
    private static var open: ProjectSettingsSheet?
    private let panel: NSPanel
    private let project: Project
    private let onSave: ([String: Any]) -> Void
    private let name = NSTextField()
    private let key = NSTextField()
    private let desc = NSTextField()
    private let agent = NSPopUpButton()
    private let worktree = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let keyNote = NSTextField(labelWithString: "")
    private let save = NSButton()

    static func show(_ p: Project, on window: NSWindow, onSave: @escaping ([String: Any]) -> Void) {
        let s = ProjectSettingsSheet(p, onSave: onSave)
        open = s
        window.beginSheet(s.panel) { _ in open = nil }
        s.panel.makeFirstResponder(s.name)
    }

    private init(_ p: Project, onSave: @escaping ([String: Any]) -> Void) {
        project = p
        self.onSave = onSave
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        super.init()
        let title = NSTextField(labelWithString: T("main.project.settings.title", p.name))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let path = NSTextField(labelWithString: (p.path.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle

        name.stringValue = p.name
        key.stringValue = p.key
        key.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        key.delegate = self
        key.placeholderString = "BA"
        keyNote.font = .systemFont(ofSize: 11)
        keyNote.textColor = .secondaryLabelColor
        keyNote.stringValue = T("main.project.key.note", p.key)
       desc.stringValue = p.description
        desc.placeholderString = T("main.project.description.placeholder")
        desc.usesSingleLineMode = false
        desc.cell?.wraps = true
        desc.cell?.isScrollable = false
        desc.lineBreakMode = .byWordWrapping
        desc.maximumNumberOfLines = 4
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.heightAnchor.constraint(equalToConstant: 62).isActive = true
        let descNote = NSTextField(wrappingLabelWithString: T("main.project.description.note"))
        descNote.font = .systemFont(ofSize: 11)
        descNote.textColor = .secondaryLabelColor

        agent.addItem(withTitle: T("main.project.agent.default"))
        agent.lastItem?.representedObject = nil
        for d in AgentHub.shared.defs {
            agent.addItem(withTitle: d.name)
            agent.lastItem?.representedObject = d.id
            if d.id == p.defaultAgent { agent.select(agent.lastItem) }
        }
        worktree.title = T("main.project.worktree")
        worktree.state = p.worktree ? .on : .off
        worktree.isEnabled = p.isGitRepo
        let wtNote = NSTextField(wrappingLabelWithString: p.isGitRepo ? T("main.project.worktree.note") : T("main.project.worktree.no_git"))
        wtNote.font = .systemFont(ofSize: 11)
        wtNote.textColor = .secondaryLabelColor

        func label(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label(T("main.project.name")), name],
            [label(T("main.project.key")), key],
            [NSGridCell.emptyContentView, keyNote],
            [label(T("main.project.description")), desc],
            [NSGridCell.emptyContentView, descNote],
            [label(T("main.project.agent")), agent],
            [NSGridCell.emptyContentView, worktree],
            [NSGridCell.emptyContentView, wtNote],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 340
        for r in [2, 4, 7] { grid.row(at: r).topPadding = -4 }

        let cancel = NSButton(title: T("action.cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        save.title = T("action.save")
        save.target = self
        save.action = #selector(saveTapped)
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, path, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: path)
        stack.setCustomSpacing(18, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        path.widthAnchor.constraint(lessThanOrEqualTo: grid.widthAnchor).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 520).isActive = true
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        validate()
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    /// K2: ^[A-Z][A-Z0-9]{1,4}$, and "IN" belongs to Unassigned.
    private var keyValid: Bool {
        let k = key.stringValue
        return k.range(of: "^[A-Z][A-Z0-9]{1,4}$", options: .regularExpression) != nil && k != "IN"
    }

    private func validate() {
        let up = key.stringValue.uppercased()
        if up != key.stringValue { key.stringValue = up }
        save.isEnabled = keyValid && !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        keyNote.stringValue = keyValid ? T("main.project.key.note", key.stringValue) : T("main.project.key.invalid")
        keyNote.textColor = keyValid ? .secondaryLabelColor : .systemRed
    }

    @objc func cancelTapped() { panel.sheetParent?.endSheet(panel) }

    @objc func saveTapped() {
        var patch: [String: Any] = [:]
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        if n != project.name { patch["name"] = n }
        if key.stringValue != project.key { patch["key"] = key.stringValue }
        if desc.stringValue != project.description { patch["description"] = desc.stringValue }
        let a = agent.selectedItem?.representedObject as? String
        if a != project.defaultAgent { patch["default_agent"] = a ?? NSNull() }
        if project.isGitRepo, (worktree.state == .on) != project.worktree { patch["worktree"] = worktree.state == .on }
        panel.sheetParent?.endSheet(panel)
        if !patch.isEmpty { onSave(patch) }
    }
}
