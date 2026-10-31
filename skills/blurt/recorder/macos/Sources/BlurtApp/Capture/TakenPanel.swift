// Used cards (v0.8.1 "Recently Taken" in the code): cards dragged out or pasted into another app in the last 7 days. A
// drop that kept only part of a card (Claude took the picture, not the note) must never lose it — so a used card leaves
// its thread but stays findable, with everything a card can do: copy it (picture + note, as a click on a card), copy
// the picture or the note alone, preview it, drag it out again (the same items as a card's drag), hang it back on the
// notch (a card again), show it in the Finder, delete it. After 7 days Snapper.expireTaken moves it to the Trash.
//
// They are the Cards panel's History segment (CardsOverview.swift): the same grid, tiles and preview as the cards
// under the notch (Current) — one look for "a set of cards" (BA-62: the old "Recently Dragged Out" panel's 56 × 40 rows
// were too small to tell apart and had no preview). That panel and its own ways in (the island's right-click menu, the
// menu bar, the main window's sidebar row and notice) are gone (v1.0.7): ⌥H and the History segment are the way in.
// This file keeps what is theirs alone: a used card's menu, and the hooks Snapper calls when they change.

import AppKit
import BlurtCore

final class TakenPanel {
    static let shared = TakenPanel()

    /// The Cards panel is open on History.
    var isOpen: Bool { CardsOverview.shared.isOpen && CardsOverview.shared.segment == .used }

    /// Tests: the Cards panel on History.
    func show() { CardsOverview.shared.show(segment: .used) }

    func hide() { if isOpen { CardsOverview.shared.hide() } }

    /// A card used, put back, expired: the panel again, if it is open.
    func reload() { CardsOverview.shared.reload() }

    /// A card was put back: the panel moves down out of the cards' strip.
    func makeRoomForCards() { CardsOverview.shared.makeRoomForCards() }

    /// The island's right-click menu: what concerns every hanging card (HangingCards.islandMenuItems: Show, Copy All,
    /// Organize All, Delete All); nothing while none hangs.
    static func islandMenu() -> NSMenu {
        let m = NSMenu()
        for (t, f) in hanging.islandMenuItems() { m.addItem(ClosureMenuItem(t, f)) }
        return m
    }

    /// A used card's menu (its right-click and "···" in the panel; Preview is put first by the panel): Copy Image ·
    /// Copy Note · Put Back Under the Notch · Show in Finder · Delete. `copy` copies it the way the panel shows (the
    /// tile's "✓ Copied"); `from`: where a card put back flies up from.
    static func menu(_ s: Shot, from: @escaping () -> NSRect?, copy: @escaping (HangingCards.Copy) -> Void) -> NSMenu {
        let m = NSMenu()
        if s.kind == .shot, s.bestURL != nil { m.addItem(ClosureMenuItem(Loc.t("capture.card.copy_image", table: "Capture")) { copy(.image) }) }
        if s.copyText != nil { m.addItem(ClosureMenuItem(Loc.t("capture.taken.copy_note", table: "Capture")) { copy(.text) }) }
        m.addItem(ClosureMenuItem(Loc.t("capture.taken.put_back", table: "Capture")) { snapper.putBack(s, from: from()) })
        if let u = s.bestURL {
            m.addItem(ClosureMenuItem(Loc.t("capture.card.reveal", table: "Capture")) { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(Loc.t("capture.card.delete", table: "Capture")) {
            snapper.delete(s)
            NotificationCenter.default.post(name: .blurtTakenChanged, object: nil, userInfo: ["count": snapper.recentlyTaken.count])
            CardsOverview.shared.reload()
        })
        return m
    }

    /// Copies a used card (test hooks; the panel copies through its tiles).
    @discardableResult
    static func copy(_ s: Shot, _ what: HangingCards.Copy) -> Bool {
        let ok = HangingCards.copyShot(s, what)
        emit(["event": "taken_copied", "n": s.n, "what": what.rawValue, "ok": ok,
              "items": (capturePasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }])
        if ok {
            var t = Island.Toast(text: Loc.t("capture.card.copied", table: "Capture"), actionTitle: nil, action: nil)
            t.icon = .check
            island.toast(t)
        }
        return ok
    }

    /// The note's first line, or "Snap · 15:30" / "Voice note · 15:30" (BlurtCore CardName).
    static func title(_ s: Shot) -> String { CardName.words(s.words) ?? s.plainName }
}

class ClosureButton: NSButton {
    private var fn: (() -> Void)?
    convenience init(_ title: String, _ fn: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.fn = fn
        target = self
        action = #selector(fire)
    }
    /// what a click does (after init: a closure that needs the button itself)
    func set(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn?() }
}
