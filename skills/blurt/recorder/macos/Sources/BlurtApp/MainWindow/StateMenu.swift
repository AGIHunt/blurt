// K3's state menu — what you can do from an item's state, and nothing else. One builder for every place it shows: the
// row's ring (click, or S on the selection), the context menu's "Change state" section, the Item menu in the menu bar
// and the command palette. Each entry is the verb, a one-line hint under it (NSMenuItem.subtitle; a two-line title
// before macOS 14.4), the ring of the state it leads to, and its key (A, D, R, W, ⌫, ⌘↩ — they work on the list).
//
// Several items selected: an action shows when it is valid for at least one of them and applies to those ("(2)" after
// the verb when that is not all of them). Writes go through `items.py state … --action A --by user` (Scripts.state);
// hand off opens the dispatch panel instead (MainWindowController.dispatch).
import AppKit
import BlurtCore

enum StateMenu {
    /// The actions offered for these items, in lifecycle order (= each state's own menu order for one item).
    static func actions(for items: [ItemRow], canHandOff: Bool) -> [String] {
        let live = items.filter { !$0.readOnly }
        return Lifecycle.actions.filter { a in (a != "hand_off" || canHandOff) && live.contains { Lifecycle.canDo(a, $0.state) } }
    }

    static func valid(_ action: String, _ items: [ItemRow]) -> [ItemRow] {
        items.filter { !$0.readOnly && Lifecycle.canDo(action, $0.state) }
    }

    /// "Mark as done — You checked, it's fixed" when every item it applies to is waiting to be verified.
    static func hint(_ action: String, _ items: [ItemRow]) -> String {
        if action == "done", !items.isEmpty, valid(action, items).allSatisfy({ $0.state == "to_verify" }) { return T("action.done.hint_verify") }
        return T("action.\(action).hint")
    }

    /// The state the action leads to (restore: the first item's restore_to, read from its file).
    static func target(_ action: String, _ items: [ItemRow]) -> String {
        if action == "restore" {
            let fm = valid(action, items).first.flatMap { FixWatcher.frontMatter($0.fileURL) } ?? [:]
            return Lifecycle.target(of: "restore", state: "discarded", restoreTo: fm["restore_to"] as? String) ?? "new"
        }
        return Lifecycle.transitions[action]?.to ?? "new"
    }

    /// The key an action shows (and has on the list): A, D, R, W, ⌫, ⌘↩.
    static func key(_ action: String) -> (String, NSEvent.ModifierFlags) {
        switch action {
        case "hand_off": return ("\r", .command)
        case "discard": return ("\u{8}", [])
        default:
            let k = Lifecycle.transitions[action]?.key ?? ""
            return (k.count == 1 ? k : "", [])
        }
    }

    static func title(_ action: String) -> String { Look.menuCase(T("action.\(action)")) }

    /// One entry. `items` decides the hint, the target ring and the "(n)" count.
    static func item(_ action: String, items: [ItemRow], selector: Selector, target: AnyObject?, keys: Bool = true) -> NSMenuItem {
        let n = valid(action, items).count
        let t = title(action) + (items.count > 1 && n < items.count ? " (\(Loc.number(n)))" : "")
        let (k, mods) = keys ? key(action) : ("", [])
        let i = NSMenuItem(title: t, action: selector, keyEquivalent: k)
        i.keyEquivalentModifierMask = mods
        i.target = target
        i.representedObject = action
        i.image = Look.ring(self.target(action, items), size: 16)
        setHint(i, hint(action, items))
        i.setAccessibilityLabel(t)
        i.setAccessibilityHelp(hint(action, items))
        return i
    }

    /// The hint under the title: the system subtitle (macOS 14.4+), else a second, smaller line of the title.
    static func setHint(_ i: NSMenuItem, _ hint: String) {
        if #available(macOS 14.4, *) {
            i.subtitle = hint
        } else {
            let s = NSMutableAttributedString(string: i.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            s.append(NSAttributedString(string: "\n" + hint, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
            i.attributedTitle = s
        }
    }

    /// The whole menu (the ring, S): the actions only, no header — the ring it opens from says where you are.
    static func menu(for items: [ItemRow], canHandOff: Bool, selector: Selector, target: AnyObject?) -> NSMenu {
        let m = NSMenu(title: T("state.menu"))
        m.autoenablesItems = false
        for a in actions(for: items, canHandOff: canHandOff) {
            let i = item(a, items: items, selector: selector, target: target)
            if a == "discard", m.items.count > 0 { m.addItem(.separator()) }
            m.addItem(i)
        }
        return m
    }
}
