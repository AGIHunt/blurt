// K3's state menu — where the item is, then what you can do from there, and nothing else. One builder for every place
// it shows: the row's ring (click, or S on the selection), the context menu's "Change state" section, the Item menu in
// the menu bar and the command palette.
//
// The ring's menu reads like a pop-up button's (Linear's status picker, Finder's): a first line that says where you are
// (the item's own ring, its state, a check; choosing it changes nothing), then the actions as single-line verbs, each with
// the shape of the state it leads to in one quiet ink (`Look.target`) and its list key — Accept A, Hand Off to Agent… ⌘↩,
// Mark as Done D, Send Back / Take Back / Reopen / Restore R, Won't Do W, Discard ⌫. The keys are the list's own, so
// the menu teaches them. Moving on comes first; setting it aside (Won't Do, Discard) is the last group. Only an action
// whose outcome isn't plain from its words carries a line under it (Discard: you can restore it); every hint is the
// entry's tooltip and its VoiceOver help, and the palette's detail.
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

    /// Setting an item aside rather than moving it on: the menu's last group.
    static let asides: Set<String> = ["wontfix", "discard"]
    /// The actions whose outcome the title alone doesn't say: their hint shows under the title, not only as a tooltip.
    static let explained: Set<String> = ["discard"]

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

    /// The entry's image: where it leads, in the one quiet ink of the menu (hand off: its paperplane).
    static func icon(_ action: String, _ items: [ItemRow], size: CGFloat = 16) -> NSImage {
        Look.target(target(action, items), size: size)
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

    /// One entry. `items` decides the hint, the target and the "(n)" count.
    static func item(_ action: String, items: [ItemRow], selector: Selector, target: AnyObject?, keys: Bool = true) -> NSMenuItem {
        let n = valid(action, items).count
        let t = title(action) + (items.count > 1 && n < items.count ? " (\(Loc.number(n)))" : "")
        let (k, mods) = keys ? key(action) : ("", [])
        let i = NSMenuItem(title: t, action: selector, keyEquivalent: k)
        i.keyEquivalentModifierMask = mods
        i.target = target
        i.representedObject = action
        i.image = icon(action, items)
        let h = hint(action, items)
        if explained.contains(action) { setHint(i, h) }
        i.toolTip = h
        i.setAccessibilityLabel(t)
        i.setAccessibilityHelp(h)
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

    /// Where the selection is now: one item — its ring, its state ("Handed off to Claude Code") and a check; several —
    /// "3 items · New, To do" (their ring and the check when they share one, else the mixed mark). Choosing it does nothing.
    static func current(_ items: [ItemRow]) -> NSMenuItem {
        let states = Lifecycle.states.filter { s in items.contains { $0.state == s } }
        let names = states.map(Look.stateName).joined(separator: Loc.isChinese ? "、" : ", ")
        let t = items.count == 1 ? Look.stateLabel(items[0]) : TP("main.items.count", items.count) + " · " + names
        // as a pop-up button's current value: there, readable (a disabled line is faint, system.md §2.4), and choosing
        // it changes nothing (no action)
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = true
        if states.count == 1 {
            i.image = Look.ring(states[0], size: 16)
            i.state = .on
        } else {
            // several states: the mixed mark (as a pop-up button shows a mixed selection), and the title in the
            // column of the others; the mark also keeps the check column, which the menu's position counts on
            i.image = NSImage(size: NSSize(width: 16, height: 16))
            i.state = .mixed
        }
        i.setAccessibilityLabel(T("state.menu.now", t))
        return i
    }

    /// The whole menu (the ring, S): where the selection is, then the actions — moving on, then setting aside.
    static func menu(for items: [ItemRow], canHandOff: Bool, selector: Selector, target: AnyObject?) -> NSMenu {
        let m = NSMenu(title: T("state.menu"))
        m.autoenablesItems = false
        let acts = actions(for: items, canHandOff: canHandOff)
        guard !acts.isEmpty else { return m }
        m.addItem(current(items))
        m.addItem(.separator())
        let on = acts.filter { !asides.contains($0) }, aside = acts.filter(asides.contains)
        for a in on { m.addItem(item(a, items: items, selector: selector, target: target)) }
        if !on.isEmpty, !aside.isEmpty { m.addItem(.separator()) }
        for a in aside { m.addItem(item(a, items: items, selector: selector, target: target)) }
        return m
    }

    /// The centre of the menu's image column from the menu window's leading edge (its transparent margin, the check
    /// column, then a 16 pt image): measured on macOS 26 (main.state-menu r1 captures).
    static let imageCenter: CGFloat = 31.5

    /// Opens the menu hanging from a row's ring, like a pop-up button: its image column straight under the ring, its
    /// top just below the row, so the row stays in view in its selection and the eye goes down from ring to ring.
    /// `ring`: the list's ring button, or the full table's State button (ring leading its title).
    static func popUp(_ m: NSMenu, from ring: NSView, in table: NSTableView, row: Int) {
        let f = ring.convert(ring.bounds, to: table)
        let x = ring is StateRingButton ? f.midX : f.minX + 7
        let r = table.rect(ofRow: row)
        m.popUp(positioning: nil, at: NSPoint(x: x - imageCenter, y: r.maxY + 3), in: table)
    }
}
