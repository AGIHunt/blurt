// New Item (BA-21: the list had no way to add one by hand): the list heading's + (and ⌘N) opens this sheet over the
// main window. A kind (Issue / Idea / To-do / Note), a title, optional details; Create writes it with `items.py add`
// into the place on show — the project in view, else the current project, else the inbox — and the list selects it.
// Nothing else to fill in: the rest (severity, module, steps) is the detail pane's, as for any item.
import AppKit
import SwiftUI
import BlurtCore

struct NewItemSheet: View {
    enum Kind: String, CaseIterable, Identifiable { case issue, idea, task, note; var id: String { rawValue } }

    /// "inbox" or a project id, and the name the sheet says it goes to
    let target: String
    let targetName: String
    var close: (_ uid: String?) -> Void

    @State private var kind: Kind = .issue
    @State private var title = ""
    @State private var details = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("main.new_item.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(T("main.new_item.into", targetName)).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { k in Text(T("kind.\(k.rawValue)")).tag(k) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.top, 14)
            TextField(T("main.new_item.title_placeholder"), text: $title)
                .textFieldStyle(.roundedBorder).focused($titleFocused).padding(.top, 12)
                .onSubmit(create)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $details).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(4)
                if details.isEmpty {
                    Text(T("main.new_item.details_placeholder")).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(.top, 10)
            HStack(spacing: 10) {
                if let e = error { Text(e).font(.system(size: 12)).foregroundStyle(Color.brandErr).lineLimit(2) }
                if saving { BrandSpinnerView(size: 12) }
                Spacer()
                Button(T("action.cancel")) { close(nil) }.keyboardShortcut(.cancelAction)
                Button(T("main.new_item.create"), action: create).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 460)
        .onAppear { titleFocused = true }
    }

    func create() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !saving else { return }
        saving = true
        error = nil
        var item: [String: Any] = ["kind": kind.rawValue, "title": t]
        let d = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { item["details"] = d }          // the item's Details section (store.BODY)
        let json = (try? JSONSerialization.data(withJSONObject: item)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        emit(["event": "item_new", "kind": kind.rawValue, "target": target == "inbox" ? "inbox" : "project"])
        Scripts.call("items.py", ["add", "--project", target, "--json", json], timeout: 30) { r in
            saving = false
            switch r {
            case .success(let o): close(o["uid"] as? String ?? (o["item"] as? [String: Any])?["uid"] as? String)
            case .failure(let f): error = f.localized
            }
        }
    }
}
