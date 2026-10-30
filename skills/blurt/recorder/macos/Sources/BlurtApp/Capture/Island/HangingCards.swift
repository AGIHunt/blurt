// The hanging cards (K7): every capture that has no project yet (no current project) hangs from the island on a thread,
// a small clasp where it holds the card (neutral; mint only on the live card: just caught, pointed at, holding the
// keyboard, picked). v0.9.1: at rest the row is straight — every top on one line, no tilt, no uneven lengths; the sway
// is motion only. v0.9.2: a row wider than the island hangs from the island's own lip — a 3 pt band of its black flush
// under it (CardRow.lip) — every card straight down on an equal thread; no drawn rod, stems or elbows.
// Replaces the v0.6 perch and its rope.
//
//  • a capture flies up while its thread drops out of the island (0.35 s ease-out) and catches it; the card sways on
//    the thread and settles within about a second.
//  • the cards hang only while you look: for a few seconds after a capture, while a note is open, and while the pointer
//    is in their region — the island, each hanging card with the strip above it where its thread runs, and the hovered
//    card's note, each with a small margin (hoverRegion; not the bounding band of the whole row). Resting on the island
//    for CardReveal.dwell (180 ms; or opening it) drops every card together with the island's detail — a brush past
//    the notch on the way to a menu drops nothing — and the island stays open while the pointer is in the region.
//    CardReveal.away (0.25 s) outside it, the threads reel the cards back into the island (its left ear counts them);
//    coming back while they are still on their way up turns them round from where they are (no restart).
//  • the row (v0.9, BlurtCore CardRow): newest first, left to right, centred under the island — at most 5 cards and
//    never wider than 780 pt (voice cards are wider, so fewer of them); the rest wait behind a quiet "+N" tile at the
//    row's end (as tall as a card, narrower: "+3" and "Show all" in secondary ink, a second sheet under it). A snap's card takes its
//    picture's shape (BlurtCore CardShape: 84 pt high, 84–150 wide; a toolbar or a sidebar shown whole). A click on the tile opens the overview
//    of every card (CardsOverview.swift). Nothing pages or rotates: the order is always the time they were taken. The
//    threads come out of the island's bottom edge straight above their cards; a row wider than the island hangs from
//    the island's lip, each card straight down from it (`origin`, `stepLip`) — never a fan, never a diagram.
//  • the cards hang from the island's bottom edge and move with it, rigidly, on the island's own spring (carry): when
//    it opens or a toast makes it taller they go down with it. (They used to follow on their own springs, lag behind
//    an opening island, slide under it and fade as if reeled in, then drop out again: the flicker when the pointer
//    came up to the island from below.) A drop already under way or showing is never started again.
//  • brought down on purpose — a click on the left ear's count, ⌥H "Show hanging cards" (record.hotkeys "cards"),
//    the menu, the main window's "Unfiled captures" — they stay (sticky) until the pointer has come to the cards and
//    gone again, or Esc; if it never comes, they stop staying 10 s later (CardReveal.staysDown), and the keyboard
//    handed back (a typed key, a click elsewhere) ends it too. Esc is a system-wide hotkey only while the pointer is
//    on them or the island, or for 4 s after they came down with it elsewhere (CardReveal.holdsEsc): an Esc for the
//    app in front is never swallowed. Esc with the pointer on the island keeps them up until it has left the island.
//    The pointer resting on the ear itself opens the island a little later (0.45 s), so its count can be clicked.
//  • the keyboard (⌥H): the panel takes the keys without activating Blurt, starting on the newest card (a ring in
//    brand.accent): ←/→, Tab / ⇧Tab move between the cards and the "+N" tile · ↩ / ⌘C copy the card and hand the
//    keyboard straight back (the next ⌘V pastes it where the user was), the cards going up a moment later · ↩ on the
//    tile opens the overview with the keyboard in it · ⌫ deletes · Esc sends them up. Any other key, a click
//    elsewhere or the cards going up hands the keyboard back (that key itself is not passed on). VoiceOver: each card
//    is a button (its words, or "Snap · 19:03"; press = copy; actions: edit, move, organize, delete), then the
//    tile ("Show all N cards", press = the overview, with the keyboard in it).
//  • what a card says (v0.8, BlurtCore CardNote): a shot shows its note along the picture's bottom edge, white on a
//    slim dark band — typed text first, then the words said; v0.9.2: one line of whole words (CardBand), the last
//    fading out when there is more, never an "…". The mic mark (leading the
//    band's first line in white — the note's, or the status's when that is all there is; a small capsule bottom right
//    only on a bare picture) when the note was spoken *and* its words are here, or it needs a retry (the audio is
//    there to try again: CardNote.marksMic). A spoken note still being transcribed: a quiet "Transcribing…" under
//    whatever was typed, never an empty mic; failed: "Couldn't transcribe" in the attention amber (it needs you; not a
//    caption) and Retry Transcription in the right-click menu; a voice note the model found no words in (v0.9): "No
//    words recognized", the same way (CardNote.needsYou). A spoken note with no speech in it (the room, a cough, abandoned
//    for typing) is dropped by Snapper/NoteBubble — wav and mark gone, the typed text stays.
//  • hover (v0.9.2) lifts the card 5 pt and grows it to 1.05x from its clasp, with the pop shadow (every item on each
//    side steps 8 pt aside, the "+N" tile too: CardRow.stepAside), its note band steps away and its × shows over the
//    top-left corner; its note, under the whole row (never over a neighbour), has the card's words (all of them) and
//    the play button of a spoken one (mint, `brand.on` glyph), then what it is and when ("Snap · 19:03"), then how to
//    use it until a card has been used once (record.cards_used) — or the keys as keycaps (KeyHint), with the keyboard
//    on the row · click = copy (rich content, see below), once the
//    double-click interval has passed (DeferredClick): double-click = edit the note, and never copies first · ⌘-click =
//    add the card to a selection that is copied as one (a neutral ring and an accent check in its corner, "✓ 2
//    selected · Copied" under the row; a plain click or the cards going up ends it) — and moved as one: drag any card of it onto a project in the island, or Move N Cards To ▸ in its
//    menu (withSelection) · right-click (HangingCards.cardMenu, this card or its selection): Copy Image / Copy Text
//    (only with text), Copy All N Cards (more than one), Retry Transcription (after a failure), Edit Note…, Show in
//    Finder, Move To ▸ (projects recently used first, then Unassigned), Organize (these cards: into Unassigned with a
//    suggested project each), Delete · drag = into any app, or onto a project in the island: the thread stretches after
//    it, then snaps and springs back up · × = the thread lets go and the card falls. Delete never asks: "Deleted · Undo"
//    in the island for 5 s (Snapper.delete; the files stay until then). The island's right-click menu (and the "+N"
//    tile's) is about every card: Show, Copy All, Organize All Cards, Delete All N Cards (one Undo for all). Filed
//    cards say so in the island — "Filed to X · AW-14 · Change" (Refile.swift: Change picks another project).
//  • the first card ever says what it is for, once, under it: "Click to copy, or drag into any app" (record
//    cards_hint_shown), after its note bubble has closed.
//  • the picture, then the note (v0.8.5; BlurtCore CardDropTarget.swift has the table and the why, CardPasteboard the
//    measurements, CardSmartPaste.swift the two-step model; Capture/CardExport.swift, CardDrag.swift, SmartPaste.swift
//    the app side). The report: a card dragged into DeepSeek's chat in a browser arrived as the picture and a .md
//    file. Browsers and Electron composers (DeepSeek, ChatGPT, Claude, Feishu, Slack…) treat anything with a file or
//    an image in it as an upload and ignore the text; WeChat and QQ (Qt) take one thing per paste or drop. So every
//    one of those gets the picture, then the note as a second paste — on a drop and on ⌘V alike — and no .md:
//      class     apps                                   drop                               ⌘V after a click-copy
//      rich      Notes, TextEdit, Mail, Pages, Keynote,  one rich item: the picture and     one rich paste (RTFD):
//                Stickies, Messages, Telegram,          the note together (RTFD) — no      picture + note, untouched
//                WhatsApp                               second step, nothing to go wrong
//      chat      browsers, Electron apps, WeChat, QQ,   the picture as the only file;      picture, then note (several
//                any app no table names                 then the note pasted into the      cards: picture, note,
//                                                       composer that received the drop    picture, note…)
//                                                       (WeChat / QQ: the rich item, which
//                                                       their composer puts the picture in
//                                                       from — v0.9, BlurtCore DragLanding)
//      terminal  Terminal, iTerm2, Ghostty, Warp…       the picture's path and the .md's   untouched
//                                                       path (Claude Code / Codex read
//                                                       it) — never the note's text
//      finder    the Finder, the Desktop                the picture file                   untouched
//    The .md (out/<NNN>/截图-HHMMSS-备注.md: the note and nothing else) is an option for chat apps and the Finder:
//    Settings → General → "Also attach the note as a .md file" (record.drag_note_file, off).
//      copy (click, ⌘-click selection, Copy All)   one rich item, every card newest first (pictures and notes as HTML,
//                                                  RTFD, RTF; the picture's PNG + TIFF; the notes as text with their
//                                                  line breaks); no file URL for one picture (with one, WebKit pastes
//                                                  nothing), each picture's file for two or more. A voice card alone:
//                                                  its words. Armed for smart paste (below).
//      drag                                        the layout for the app under the pointer (CardDropTarget): the
//                                                  window there in CGWindowList z-order, skipping ours, its owner's
//                                                  bundle id. Lazily provided, and written again when the pointer
//                                                  moves into an app of a class with another layout (the pasteboard
//                                                  keeps the first answer otherwise, and apps read while a drag only
//                                                  passes over them). Optional (record.drag_caption, off): the picture
//                                                  is a copy with the note burned in under it. A voice card: its
//                                                  words only, whatever the app.
//  • the second step (record.smart_paste, on; needs Accessibility): (1) for 2 minutes after a copy, while the
//    clipboard still holds it (its change count), ⌘V in a chat app runs a sequence instead — each picture alone, then
//    its note alone, one paste each, each step once the app has read the last (a note with more after it ends its
//    line) — then the card copy is back on the clipboard (armed again) and the island says "图 + 文已粘贴". An active
//    event tap, only while a copy is armed; ⌘V in Blurt, a rich app, a terminal or the Finder passes untouched.
//    (2) after a drop into a chat app (only when it got the chat layout: one that read the rich layout by mistake
//    already has the note): the app comes forward at that window; the composer that received the drop gets the focus
//    if it hasn't (the editable text under the drop point, else the nearest one in that window — a chat page is often
//    all drop zone); the caret goes after the picture (WeChat / QQ ⌘↓ — their dropped picture stays selected; a
//    selection →; a caret nothing — the picture became an attachment; can't tell ⌘↓); the note goes in as one paste;
//    the clipboard comes back. Web content whose focus Accessibility can't confirm still gets the paste, as dictation
//    does; an unknown native app only into editable text. Never when Blurt is in front, under secure input, or when the
//    focus is in another window. It counts only if the app read the note. The toast: "Dragged out · picture and note".
//    Off, no Accessibility, or it couldn't: the picture alone, and the safety net copies the note ("… picture · note
//    copied, ⌘V to paste").
//  • a drag's plain text (rich apps only) is one line, control characters out (CardTransfer.dragText): the app that
//    reads it is the one under the pointer at that moment, which may not be where it lands. A copy keeps the note's
//    line breaks (pasting is the user's own act), and so does the note pasted after a drop (it went where it landed).
//  • dropped in another app (the session ended with an operation, over a window that isn't ours): the card has been
//    used, so it leaves its thread — "taken" (Snapper.takeOut: `{"n","taken":wall}`), not discarded: its files stay,
//    and it is in Recently Taken for 7 days (the island's right-click menu, the main window; TakenPanel.swift: copy,
//    drag out again, put back), then housekeeping trashes it. Where the note didn't go in (a chat app whose second
//    step couldn't run, the Finder without the .md, or not sure what it got), it also goes on the clipboard
//    (record.drag_copy_note, on by default; DragReceipt.copiesNote); a rich app, a chat app that got the note pasted
//    and a terminal leave the clipboard alone. The toast says what went in (DragReceipt): "Dragged out · picture and
//    note" (rich apps, chat apps with the note pasted), "… picture and note paths" in a terminal (no ⌘V: that would
//    paste at a prompt), "… picture · note copied, ⌘V to paste" where only the picture went in, "Dragged out · note
//    copied, ⌘V to paste" when it isn't the kind of app the pasteboard was last written for. Undo puts the card back
//    and the clipboard as it was. It went with the drag, so nothing falls: the thread lets go and its free end springs
//    back into the island, and the others close up. Dropped on nothing (or on one of our windows): it comes back to
//    its thread; on a project in the island: filed.
//  • a voice card is a text card: up to two lines of its words and a small mic mark (it was spoken). Dragged before
//    its words are written down, the drag waits for them (up to 1 s, while the pointer keeps moving), else it stays
//    and says "The words aren't ready yet" under the card. Its hover note keeps the small play button.
//    v0.8.6 — into a chat app it drops anywhere in the window (BlurtCore VoiceCardDrop: Electron and browser pages take
//    dropped text only on their message box, and show their drop overlay only for files): over such a window the drag
//    image says "松手粘贴到 Claude" (CardDrag draws the hint under the card; a refused drop doesn't fly back), and let
//    go of anywhere there, Blurt pastes the words into that window's composer (Snapper.takeOutVoice → the shot cards'
//    DragNoteFollowUp). Notes, TextEdit, terminals: the normal text drop (one line; never a Return).
//    v0.9 — over a browser / Electron / Feishu window, when Blurt can paste, the drag carries no words at all (only the
//    capture's tag): Feishu took a text drop and put nothing in. Blurt pastes them there taken or not; WeChat / QQ
//    keep their own text drop (BlurtCore VoiceCardDrop.withholdsWords).
//  • assigned (dropped on a project, a capture with a current project, "Let AI sort"): the thread reels the card up
//    into the island, which swallows it with a small bump.
//  • 12 pt apart, straight (the row itself: above).
//  • Reduce Motion: 0.2 s fades, no sway.
// Window: a non-activating panel on all spaces, never in Blurt's own captures, mouse-transparent except over a card; it lives on the
// island's screen. The display link runs only while something moves, and stops before the panel is ordered out (an
// off-screen window's link never fires again: the idle polls that bring the cards back on hover would stop with it).

import AppKit
import AVFoundation
import BlurtCore
import Carbon.HIToolbox
import QuartzCore

final class HangingCard {
    let shot: Shot
    let root = CALayer()            // pivot: the clasp (the card's top centre); the card hangs from it
    let thread = CAShapeLayer()     // from inside the island down to the clasp (in the stage: it never rotates)
    let clasp = CALayer()
    let card = CALayer()            // shadow + shape
    let face = CALayer()            // photo / voice face, clipped
    let title = CATextLayer()       // voice cards: the words
    let scrim = CAGradientLayer()   // shot cards: the dark band under the note
    let caption = CATextLayer()     // shot cards: the note (typed, then said)
    let captionStatus = CATextLayer()   // shot cards: "Transcribing…" / "Couldn't transcribe"
    let badge = CALayer()
    /// shot cards with a caption: the marks (spoken, inked) inline before the note, never a capsule over the picture
    let captionMarks = CALayer()
    let close = CALayer()
    /// the small dark pill under the card ("✓ Copied", a hint): its text, and the ok check before a done notice
    let copied = CALayer(), copiedText = CATextLayer(), copiedCheck = CALayer()
    var size: CGSize
    /// where the thread holds the top edge, from the card's left: the middle (a picture, or a voice note's words)
    let gripX: CGFloat
    var x: Spring
    var grip: Spring                // y of the card's top edge (the thread's end), panel coordinates (y down)
    var theta: CGFloat = 0, omega: CGFloat = 0     // sway, degrees
    /// v0.9.1: no resting tilt — the cards hang straight on one top line; they sway only while something moves them
    let tilt: CGFloat = 0
    /// the way it turns as it falls (deleted): alternate cards fall to alternate sides
    let side: CGFloat
    var slack: CGFloat = 0          // this card's extra thread length (0: every top on one line)
    /// the clasp is mint until then: the card just caught (blurt in the act); hovered, focused or picked too
    var liveUntil: CFTimeInterval = 0
    var claspLive: Bool?
    /// a ⌘-click selection: a ring in brand.accent outside the card and a check badge in its corner (never colour alone)
    let pickRing = CALayer()
    let pickBadge = CALayer()
    var opacity: CGFloat = 0
    var lift = Spring(0, response: 0.28, damping: 0.75)
    var hovered = false
    var dragging = false
    var flying = false              // the capture is still in the air
    var copiedUntil: CFTimeInterval = 0
    /// leaving: falling (delete) or pulled into the island
    var leaving: (start: CFTimeInterval, into: CGPoint?, from: CGPoint)?
    /// leaving because it was dragged out and dropped in another app: the card is already gone (it went with the
    /// drag); only its thread lets go and settles back up — no fall
    var taken = false
    /// the thread dropping out of the island: 0.35 s ease-out from `from` to `to`, starting at `start` (then the spring)
    var reach: (start: CFTimeInterval, from: CGFloat, to: CGFloat)?
    /// how much of the thread shows, from the island down (0…1): it unreels again after a drag comes back
    var unreel: (start: CFTimeInterval, duration: CFTimeInterval)?
    /// dragged away: the thread follows the pointer (`end`, panel coordinates) until it snaps at `snapped`
    var tether: (end: CGPoint, snapped: CFTimeInterval?, from: CGPoint)?
    /// assigned while still in the air: pulled into the island right after the catch
    var pullAfterCatch = false
    /// behind the "+N" tile: it fades out as it slides under it (a voice card is wider than the tile)
    var piled = false
    /// the card cuts its note short (the hover note then shows all of it)
    var truncated = false
    /// the keyboard is on this card (⌥H): a ring in brand.accent
    let focusRing = CALayer()

    init(_ s: Shot, x: CGFloat, side: CGFloat) {
        shot = s
        size = s.kind == .voice ? HangingCards.voiceSize : HangingCards.shotFit(s).size
        gripX = size.width / 2
        self.x = Spring(x, response: 0.5, damping: 0.82)
        grip = Spring(-HangingCards.shotSize.height - 40, response: 0.55, damping: 0.72)
        self.side = side
    }
}

/// Key-able only while the keyboard is on the cards (⌥H), and never activating: the app the user was in stays in front.
final class CardsPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

final class CardsView: NSView, NSDraggingSource {
    weak var cards: HangingCards?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if cards?.key(e) != true { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) { cards?.mouseDown(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { cards?.mouseDragged(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { cards?.mouseUp(e, at: convert(e.locationInWindow, from: nil)) }
    override func rightMouseDown(with e: NSEvent) { cards?.rightMouseDown(e, at: convert(e.locationInWindow, from: nil)) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { Loc.t("capture.cards.ax", table: "Capture") }
    override func accessibilityChildren() -> [Any]? { cards?.accessibilityElements() ?? [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        (cards?.accessibilityElements() ?? []).reversed().first { $0.accessibilityFrame().contains(point) } ?? self
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : [.generic, .move]
    }
    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) { cards?.dragMoved(to: p) }
    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        cards?.dragEnded(at: p, operation: operation)
    }
}

/// A drawn card as an accessibility element: its frame follows the layer.
final class LayerAXElement: NSAccessibilityElement {
    weak var layer: CALayer?
    weak var host: NSView?
    var press: (() -> Void)?

    static func make(role: NSAccessibility.Role, layer: CALayer, host: NSView) -> LayerAXElement {
        let e = LayerAXElement()
        e.setAccessibilityRole(role)
        e.setAccessibilityParent(host)
        e.layer = layer
        e.host = host
        return e
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityFrame() -> NSRect {
        guard let l = layer, let v = host, let root = v.layer, let w = v.window else { return .zero }
        return w.convertToScreen(v.convert(l.convert(l.bounds, to: root), to: nil))
    }
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}

/// The pasteboard type a card carries inside the app: "<batch dir>\n<n>".
let capturePasteboardType = NSPasteboard.PasteboardType("dev.blurt.capture")

final class HangingCards: NSObject {
    static let shotSize = CGSize(width: 112, height: 84)
    /// A snap's card follows its picture (BlurtCore CardShape): 84 pt high, 84…150 wide; a toolbar or a sidebar is
    /// shown whole on the card's surface instead of as a blown-up slice of its middle.
    static func shotFit(_ s: Shot) -> CardShape.Fit {
        let px = s.pixelSize.width > 0 ? s.pixelSize : (s.markedThumb ?? s.thumb).map { CGSize(width: $0.width, height: $0.height) }
        return CardShape.shot(px)
    }
    static let voiceSize = CGSize(width: 168, height: 50)
    static let gap: CGFloat = 12
    static let edge: CGFloat = 12                  // the cards keep this far from the screen's edges
    static let below: CGFloat = 18                 // the cards' top edge under the island (every card's)
    /// v0.9.2: a row wider than the island hangs from the island's own lip — a band of its black this thick, flush
    /// under its bottom edge (`stepLip`), never a drawn rod with stems.
    static let lipT: CGFloat = 3
    /// The lifted card (hover, the keyboard): this much higher, 1.05 larger from its clasp, the pop shadow.
    static let liftPt: CGFloat = 5
    static let liftScale: CGFloat = 0.05
    /// …and the items on each side of it step this far aside (the tile too): the gap beside it never drops under `gap`.
    static let aside: CGFloat = 8
    /// v0.9.1: no extra thread per position any more — uneven ends, a ±2° tilt and fanned threads read as jitter at
    /// rest; every card's top is on one line, and a row wider than the island hangs from a rod (see `origin`).
    static let slacks: [CGFloat] = [0]
    static let claspSize: CGFloat = 5
    /// The "+N" tile: as tall as a card, narrower — a quiet way into the overview, not the row's headline.
    static let tileSize = CGSize(width: 72, height: 84)
    /// Resting card shadow (light / dark) and how much a hovered card adds: one tight elevation for the row.
    // flat, as the site (BA-8, v1.0.4): the 0.5 pt edge carries the card; the shadow only lifts it off the page
    static let shadowLight: Float = 0.1, shadowDark: Float = 0.3, shadowLift: Float = 0.06
    static let voiceMicName = "voiceMic"
    static let panelH: CGFloat = 640

    /// A dynamic brand colour resolved for the cards' appearance (they follow the app's light / dark — isDarkMode —
    /// not the drawing appearance of whatever happens to be current when a layer is styled). Increase Contrast still
    /// applies (BrandColor checks it itself).
    static func cardColor(_ c: NSColor, dark: Bool) -> CGColor {
        var out = c.cgColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }

    private var panel: CardsPanel?
    private var view: CardsView!
    private let stage = CALayer()
    private var cards: [HangingCard] = []
    private var leaving: [HangingCard] = []
    /// The "+N" tile at the row's end: the next card that doesn't hang (dimmed), a second edge behind it, and the count.
    private let stack = CALayer(), stackFace = CALayer(), stackBack = CALayer(), stackText = CATextLayer()
    private let stackCaption = CATextLayer()
    /// The keyboard on the tile: the same ring as on a card, 4 pt outside it.
    private let tileRing = CALayer()
    private let stackThread = CAShapeLayer(), stackClasp = CALayer()
    /// The island's lip a row wider than the island hangs from (v0.9.2): the island's own black, flush under it.
    private let lip = CAShapeLayer()
    /// Where the threads leave the lip (panel y) and how far the row is down (0…1: the lip grows out with it).
    private var lipY: CGFloat = 0
    private var lipK: CGFloat = 0
    /// The "+N" tile's x: it steps aside with the cards, on a spring like theirs.
    private var tileX = Spring(0, response: 0.5, damping: 0.82)
    private var stackLive: Bool?
    /// A ⌘-click selection's one line under the row: "2 selected · Copied".
    private let selPill = CALayer(), selText = CATextLayer(), selCheck = CALayer()
    private var pickedCopied = false
    /// The row as laid out last (CardRow.layout): which cards hang, newest first, and where the tile is.
    private var row = CardRow.Layout.empty
    private let tip = CALayer(), tipText = CATextLayer(), tipPlay = CALayer()
    /// The hover note's quiet lines: what the card is and when ("Snap · 19:03"), then how to use it (until the
    /// user has used a card once) or, with the keyboard on the row, its keys.
    private let tipMeta = CATextLayer(), tipHint = CATextLayer()
    /// The keys as keycaps (KeyHint), with the keyboard on the row.
    private let tipKeys = CALayer()
    private var driver: MotionDriver?
    private(set) var screen: NSScreen?
    private var width: CGFloat = 1440

    private var peekUntil: CFTimeInterval = 0
    private var holds = 0
    private var awaySince: CFTimeInterval?
    private var shown = false                      // the cards are down
    /// Brought down on purpose (the ear's count, ⌥H, the menu, the main window): down until the pointer has been on
    /// the cards (`visited`) and left them and the island, or Esc.
    private var sticky = false
    private var visited = false
    private var revealedAt: CFTimeInterval = 0
    private var escHeld = false
    /// Esc sent them up with the pointer on the island: they stay up until it has left the island (resting there
    /// would otherwise bring them straight back down).
    private var upTillLeaves = false
    /// The pointer is over a card, the "+N" stack or a card's note (the island stays open meanwhile).
    private(set) var pointerOver = false
    private var hoverCard: HangingCard?
    private var hoverSince: CFTimeInterval = 0
    private var down: (p: NSPoint, card: HangingCard?, event: NSEvent, dragged: Bool)?
    /// A plain click copies after the double-click interval (a double-click edits instead): DeferredClick.
    private var click = DeferredClick<ObjectIdentifier>()
    /// The keyboard's stop on the row (CardFocus: 0 = the newest card, then the "+N" tile); nil: not on the cards.
    private var focus: Int?
    private(set) var dragging: HangingCard?
    private var player: AVAudioPlayer?

    var count: Int { cards.count }
    private var visible: Bool { shown || !leaving.isEmpty || cards.contains { reeled($0) > 0.01 } }

    // MARK: window

    private func ensurePanel(on s: NSScreen) {
        let f = NSRect(x: s.frame.minX, y: s.frame.maxY - HangingCards.panelH, width: s.frame.width, height: HangingCards.panelH)
        if panel == nil {
            let p = CardsPanel(contentRect: f, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true          // (before the level: it resets the level to .floating)
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = chromeSharing
            p.setAccessibilityTitle(Loc.t("capture.cards.ax", table: "Capture"))
            let v = CardsView(frame: NSRect(origin: .zero, size: f.size))
            v.cards = self
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            v.layer?.addSublayer(stage)
            p.contentView = v
            view = v
            panel = p
            buildChrome()
            let d = MotionDriver(view: v)
            d.tick = { [weak self] dt in self?.frame(dt) ?? false }
            d.idle = { [weak self] in self?.poll(CACurrentMediaTime()) }
            driver = d
            NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: p)
        }
        screen = s
        width = f.width
        panel?.setFrame(f, display: false)
        view.frame = NSRect(origin: .zero, size: f.size)
        stage.frame = view.bounds
    }

    private func buildChrome() {
        for l in [stack, stackBack] {
            l.cornerRadius = 7
            l.borderWidth = 0.5
            l.shadowColor = NSColor.black.cgColor
            l.isHidden = true
        }
        stack.shadowRadius = 3
        stack.shadowOffset = CGSize(width: 0, height: 1)
        stackBack.shadowOpacity = 0
        stackFace.cornerRadius = 7
        stackFace.masksToBounds = true
        stackFace.contentsGravity = .resizeAspectFill
        stack.addSublayer(stackFace)
        stackThread.isHidden = true
        stackClasp.isHidden = true
        lip.zPosition = -1
        lip.fillColor = NSColor.black.cgColor          // the island's own black (it is always black)
        lip.strokeColor = nil
        stage.addSublayer(lip)
        stage.addSublayer(stackThread)
        stage.addSublayer(stackClasp)
        for t in [stackText, stackCaption] {
            t.contentsScale = 2
            t.alignmentMode = .center
            stack.addSublayer(t)
        }
        tileRing.frame = CGRect(origin: .zero, size: HangingCards.tileSize).insetBy(dx: -4, dy: -4)
        tileRing.cornerRadius = 11
        tileRing.borderWidth = 2
        tileRing.isHidden = true
        stack.addSublayer(tileRing)
        selPill.zPosition = 10_001
        selPill.cornerRadius = 12
        selPill.isHidden = true
        selPill.shadowOpacity = 0.2
        selPill.shadowRadius = 3
        selPill.shadowOffset = CGSize(width: 0, height: 3)
        selPill.borderWidth = 0.5
        selText.contentsScale = 2
        selText.alignmentMode = .left
        selPill.addSublayer(selText)
        selCheck.contentsGravity = .resizeAspect
        selPill.addSublayer(selCheck)
        stage.addSublayer(selPill)
        tipMeta.truncationMode = .end           // (plain strings: setText)
        tipHint.truncationMode = .end
        for l in [tipMeta, tipHint] {
            l.contentsScale = 2
            tip.addSublayer(l)
        }
        tipKeys.contentsScale = 2
        tipKeys.contentsGravity = .resizeAspect
        tip.addSublayer(tipKeys)
        stage.addSublayer(stackBack)
        stage.addSublayer(stack)
        // above every card (their zPosition is their index), so the piled ones go under it, not over "+N"
        stackThread.zPosition = 9_998
        stackBack.zPosition = 9_998.5
        stack.zPosition = 9_999
        stackClasp.zPosition = 10_000
        tip.zPosition = 10_001                        // the hovered card's note goes over its neighbours, never under
        tip.cornerRadius = 10
        tip.shadowOpacity = 0.22
        tip.shadowRadius = 4
        tip.shadowOffset = CGSize(width: 0, height: 4)
        tip.isHidden = true
        tipText.contentsScale = 2
        tipText.isWrapped = true
        tipText.truncationMode = .end
        tip.addSublayer(tipText)
        tipPlay.cornerRadius = 11
        tip.addSublayer(tipPlay)
        stage.addSublayer(tip)
        restyle()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(themeChanged),
                                                            name: .init("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func themeChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.restyle() } }

    private var styledDark = false

    private func restyle() {
        let dark = isDarkMode
        styledDark = dark
        tipFor = nil                                  // the note's text colour follows on the next hover
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in cards { style(c) }
        // the "+N" tile: an opaque, quiet surface (in dark a step under the cards, never a grey translucent block)
        // and no second sheet under it (a 4 pt sliver read as a doubled shadow)
        stack.backgroundColor = HangingCards.tileSurface(dark: dark).cgColor
        stack.borderColor = HangingCards.hairline(dark: dark).cgColor
        stackBack.isHidden = true
        stack.shadowOpacity = dark ? HangingCards.shadowDark : HangingCards.shadowLight
        // the hover note and the selection line: one solid surface (a tip, radius 10) — the elevated #2A2A2A in dark,
        // never a translucent grey that reads as disabled
        for l in [tip, selPill] {
            l.backgroundColor = HangingCards.tipSurface(dark: dark).cgColor
            l.borderColor = HangingCards.hairline(dark: dark).cgColor
            l.borderWidth = 0.5
        }
        tip.shadowOpacity = dark ? 0.4 : 0.16
        tipPlay.backgroundColor = BrandColor.fill.cgColor                 // the note's play button: flat mint, dark glyph
        styleThread(stackThread, stackClasp)
        stackLive = nil
        updateSelection()
        CATransaction.commit()
        if !stack.isHidden { layout() }              // "+N" in the new colours
    }

    // MARK: building a card

    /// The cards' opaque surface (a picture shown whole is letterboxed on it; the "+N" tile is made of it).
    /// A solid rounded surface's shadow follows its outline (set with its size), so Core Animation doesn't find it
    /// from the pixels of the layer and everything on it on every frame a card moves.
    static func shadowAlongEdge(_ l: CALayer) {
        let r = min(l.cornerRadius, l.bounds.width / 2, l.bounds.height / 2)
        l.shadowPath = CGPath(roundedRect: l.bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    static func surface(dark: Bool) -> NSColor {
        dark ? NSColor(calibratedWhite: 0.2, alpha: 0.98) : NSColor(calibratedWhite: 0.985, alpha: 0.99)
    }
    /// The "+N" tile's surface: opaque, a step quieter than a card's in dark.
    static func tileSurface(dark: Bool) -> NSColor {
        dark ? NSColor(calibratedWhite: 0.145, alpha: 1) : NSColor(calibratedWhite: 0.985, alpha: 1)
    }
    /// The hover note's and the selection line's surface: one solid elevated sheet (#2A2A2A in dark, white in light).
    static func tipSurface(dark: Bool) -> NSColor {
        dark ? NSColor(calibratedWhite: 0.165, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 1)
    }
    /// The 0.5 pt edge every card, the tile and the tips share (it holds the edge where the shadow can't: dark mode,
    /// a light picture on a light wallpaper).
    static func hairline(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12) }

    /// One hairline in both appearances: 1 pt of ink at about a third, with only a faint 0.5 pt halo of the opposite
    /// tone (a wide halo turned dark mode's thread into a soft grey band).
    private func styleLine(_ t: CAShapeLayer) {
        let dark = isDarkMode
        t.strokeColor = (dark ? NSColor(white: 1, alpha: 0.42) : NSColor(white: 0, alpha: 0.34)).cgColor
        t.fillColor = nil
        t.lineWidth = 1
        t.lineCap = .round
        t.shadowColor = (dark ? NSColor.black : NSColor.white).cgColor
        t.shadowOpacity = 0.3
        t.shadowRadius = 0.5
        t.shadowOffset = .zero
    }

    /// A thread and its clasp: a small neutral dot (the card surface, ringed in the thread's ink), just above the card's
    /// top edge (it never covers the picture's own title); it turns mint only on the card just caught (`liveClasp`).
    private func styleThread(_ t: CAShapeLayer, _ k: CALayer) {
        let dark = isDarkMode
        styleLine(t)
        let d = HangingCards.claspSize
        k.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        k.cornerRadius = d / 2
        k.borderWidth = 1
        k.shadowColor = NSColor.black.cgColor
        k.shadowOpacity = dark ? 0.4 : 0.18
        k.shadowRadius = 1
        k.shadowOffset = CGSize(width: 0, height: 0.5)
        liveClasp(k, false, dark: dark)
    }

    private func liveClasp(_ k: CALayer, _ live: Bool, dark: Bool) {
        k.backgroundColor = live ? BrandColor.fill.cgColor : HangingCards.surface(dark: dark).withAlphaComponent(1).cgColor
        k.borderColor = live ? HangingCards.surface(dark: dark).withAlphaComponent(1).cgColor
            : (dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.38)).cgColor
    }

    /// A plain string with the layer's own font and colour: an NSAttributedString in a CATextLayer with a truncation
    /// mode draws nothing at all once it overflows (macOS 26), so the voice cards' words and long tips went blank.
    static func setText(_ l: CATextLayer, _ text: String, font: NSFont, color: NSColor) {
        l.string = text
        l.font = font
        l.fontSize = font.pointSize
        l.foregroundColor = color.cgColor
    }
    private func setText(_ l: CATextLayer, _ text: String, font: NSFont, color: NSColor) { HangingCards.setText(l, text, font: font, color: color) }

    private func style(_ c: HangingCard) {
        let dark = isDarkMode
        styleThread(c.thread, c.clasp)
        c.claspLive = nil
        styleClose(c, dark: dark)
        let s = c.shot
        let note = s.note
        if s.kind == .voice {
            c.card.backgroundColor = (dark ? NSColor(calibratedWhite: 0.17, alpha: 0.98) : NSColor(calibratedWhite: 0.995, alpha: 0.99)).cgColor
            let f = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let words = s.words ?? note.text      // (note.text: the words heard while it was said, until its own are in)
            let dur = HangingCards.clock(s.duration ?? 0)
            let text = words ?? HangingCards.statusText(note.status) ?? Loc.t("capture.voice.card_empty", table: "Capture", dur)
            // "Couldn't transcribe" needs you: the attention colour, never the quiet grey of a placeholder
            let quiet = NSColor(white: dark ? 1 : 0, alpha: 0.5)
            let title = words != nil ? (dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.08, alpha: 1))
                : note.needsYou ? NSColor(cgColor: HangingCards.cardColor(BrandColor.attnInk, dark: dark)) ?? quiet : quiet
            setText(c.title, text, font: f, color: title)
            let fit = (text as NSString).boundingRect(with: NSSize(width: c.title.frame.width, height: 400), options: [.usesLineFragmentOrigin],
                                                      attributes: [.font: f]).height
            c.truncated = words != nil && fit > c.title.frame.height + 1
            // the mic mark: brand ink on the card face (deep mint on light, mint on dark)
            if let mic = c.card.sublayers?.first(where: { $0.name == HangingCards.voiceMicName }) {
                mic.contents = BlurtIcon.mic.cgImage(size: 11, scale: mic.contentsScale, color: HangingCards.cardColor(BrandColor.ink, dark: dark))
            }
        } else {
            // the card's own opaque surface, as the "+N" tile and the overview tiles: a picture shown whole (a toolbar,
            // a sidebar) is letterboxed on it — a translucent grey picked up the wallpaper, half blue and half grey
            c.card.backgroundColor = HangingCards.surface(dark: dark).cgColor
            // a picture that fills is cut from its top-left corner, as its overview tile is (OverviewTile.topLeading):
            // the card and its tile show the same slice (the centre crop showed "kout" where the tile said "heckout")
            if let t = s.markedThumb ?? s.thumb, HangingCards.shotFit(s).fills, c.face.bounds.width > 0, c.face.bounds.height > 0 {
                c.face.contents = OverviewTile.topLeading(t, box: c.face.bounds.size)
                c.face.contentsGravity = .resize
            } else {
                c.face.contents = s.markedThumb ?? s.thumb
            }
            layoutCaption(c, note, marks: HangingCards.marks(s))
        }
        c.card.shadowOpacity = dark ? HangingCards.shadowDark : HangingCards.shadowLight
        stylePick(c)                    // a ⌘-click selection's ring survives a restyle (appearance, a new note)
        // the mic mark: these words were spoken (or the audio waits for a retry) — never on a card without them
        let marks = HangingCards.marks(s)
        // on a bare picture: the small capsule in its bottom right corner; with a band (a note, or only its status
        // line), the marks lead the band's first line (white, on the dark band) — a capsule moved to the top corner
        // covered what was there ("$24.00"), and one in the corner covered "Couldn't transcribe"
        let banded = s.kind == .shot && !c.scrim.isHidden
        let w = c.size.width, h = c.size.height
        c.badge.contents = marks.isEmpty || banded ? nil : HangingCards.badgeImage(marks)
        c.badge.isHidden = marks.isEmpty || banded
        let badgeW = HangingCards.badgeWidth(marks.count)
        c.badge.frame = CGRect(x: w - 6 - badgeW, y: h - 6 - 16, width: badgeW, height: 16)
        c.captionMarks.isHidden = marks.isEmpty || !banded
        if banded, !marks.isEmpty {
            c.captionMarks.contents = HangingCards.inlineMarksImage(marks)
            c.captionMarks.frame = CGRect(x: 7, y: c.caption.frame.midY - 5,
                                          width: HangingCards.inlineMarksWidth(marks.count), height: 10)
        }
    }

    /// What a card is marked with: its words were spoken (when they are here, or the audio waits for a retry), ink.
    static func marks(_ s: Shot) -> [BlurtIcon] {
        (s.kind == .shot && s.note.marksMic ? [.mic] : []) + (s.marked != nil ? [.ink] : [])
    }

    /// "Transcribing…" / "Couldn't transcribe" / "No words recognized" (nil: nothing pending).
    static func statusText(_ s: CardNote.Status) -> String? {
        switch s {
        case .none: return nil
        case .transcribing: return Loc.t("capture.card.transcribing", table: "Capture")
        case .failed: return Loc.t("capture.card.transcribe_failed", table: "Capture")
        case .noWords: return Loc.t("capture.card.no_words", table: "Capture")
        }
    }

    /// v0.9.2: a shot card's note is one line on a slim band along its bottom edge (19 pt, 11 pt medium white): the
    /// longest run of whole words that fits (CardBand.clamp), its end fading out when there is more — never an "…", and
    /// never more than a fifth of the picture (the evidence stays in view). A note that needs you ("Couldn't
    /// transcribe") takes the line instead, in the attention colour. The hover note has all of it; the band steps away
    /// while the card is lifted (`place`), so the words never show twice.
    static let bandH: CGFloat = 19
    private func layoutCaption(_ c: HangingCard, _ note: CardNote, marks: [BlurtIcon]) {
        let w = c.size.width, h = c.size.height
        let f = NSFont.systemFont(ofSize: 11, weight: .medium)
        let status = HangingCards.statusText(note.status)
        let text = note.text.map { $0.replacingOccurrences(of: "\n", with: " ") }
        let needs = note.needsYou && status != nil
        let line = needs ? status : (text ?? status)
        c.caption.isHidden = line == nil
        c.captionStatus.isHidden = true
        c.scrim.isHidden = line == nil
        c.truncated = text != nil
        guard let l = line else { return }
        let lead = marks.isEmpty ? 0 : HangingCards.inlineMarksWidth(marks.count) + 4
        let inner = w - 14 - lead
        let fits = { (t: String) in ceil((t as NSString).size(withAttributes: [.font: f]).width) <= inner }
        let band = CardBand.clamp(l, fits: fits)
        let color = needs ? BrandColor.Island.attn : (text == nil ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 1, alpha: 0.96))
        setText(c.caption, band.text, font: f, color: color)
        let bh = HangingCards.bandH
        c.caption.frame = CGRect(x: 7 + lead, y: h - bh + (bh - 14) / 2, width: inner, height: 14)
        // more than fits: the line's end fades out (the last 16 pt), not an ellipsis
        if band.clipped {
            let m = (c.caption.mask as? CAGradientLayer) ?? CAGradientLayer()
            m.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            m.startPoint = CGPoint(x: 0, y: 0.5)
            m.endPoint = CGPoint(x: 1, y: 0.5)
            // (the fade sits on the last word, wherever the line ends — not at the band's edge)
            let end = min(inner, ceil((band.text as NSString).size(withAttributes: [.font: f]).width) + 2)
            m.locations = [0, NSNumber(value: Double(max(0, end - 18) / inner)), NSNumber(value: Double(end / inner))]
            m.frame = CGRect(origin: .zero, size: c.caption.frame.size)
            c.caption.mask = m
        } else {
            c.caption.mask = nil
        }
        c.scrim.frame = CGRect(x: 0, y: h - bh - 6, width: w, height: bh + 6)
    }

    static func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    static func badgeWidth(_ n: Int) -> CGFloat { 5 * 2 + CGFloat(max(1, n)) * 10 + CGFloat(max(0, n - 1)) * 3 }
    static func inlineMarksWidth(_ n: Int) -> CGFloat { CGFloat(max(1, n)) * 9 + CGFloat(max(0, n - 1)) * 2 }

    /// The marks before a caption: white, 9 pt, no capsule (the note's dark band is under them).
    static func inlineMarksImage(_ icons: [BlurtIcon]) -> CGImage? {
        renderImage(CGSize(width: inlineMarksWidth(icons.count), height: 10)) { ctx in
            for (i, ic) in icons.enumerated() {
                ic.draw(in: ctx, rect: CGRect(x: CGFloat(i) * 11, y: 0.5, width: 9, height: 9), color: CGColor(gray: 1, alpha: 0.96))
            }
        }
    }

    /// The small dark capsule with the card's indicator icons (voice note, ink).
    static func badgeImage(_ icons: [BlurtIcon]) -> CGImage? {
        let side: CGFloat = 10, gap: CGFloat = 3, pad: CGFloat = 5
        let w = badgeWidth(icons.count), h: CGFloat = 16
        return renderImage(CGSize(width: w, height: h)) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            for (i, ic) in icons.enumerated() {
                ic.draw(in: ctx, rect: CGRect(x: pad + CGFloat(i) * (side + gap), y: 3, width: side, height: side), color: CGColor(gray: 1, alpha: 0.95))
            }
        }
    }

    private func makeCard(_ s: Shot, x: CGFloat) -> HangingCard {
        let i = cards.count + leaving.count
        let c = HangingCard(s, x: x, side: i % 2 == 0 ? 1 : -1)
        let w = c.size.width, h = c.size.height
        // the thread lives in the stage (it never rotates); the card and its clasp hang from root
        c.grip.target = threadTop
        c.grip.snap()                        // a new card comes out of the island
        stage.insertSublayer(c.thread, below: stackBack)
        c.root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        c.root.anchorPoint = CGPoint(x: c.gripX / w, y: 0)
        c.root.opacity = 0
        c.card.frame = CGRect(x: 0, y: 0, width: w, height: h)
        c.card.cornerRadius = s.kind == .voice ? 12 : 7
        c.card.borderWidth = 0.5
        c.card.shadowColor = NSColor.black.cgColor
        c.card.shadowRadius = 3
        c.card.shadowOffset = CGSize(width: 0, height: 1)
        HangingCards.shadowAlongEdge(c.card)
        c.face.frame = c.card.bounds
        c.face.cornerRadius = c.card.cornerRadius
        c.face.masksToBounds = true
        c.face.contentsGravity = s.kind == .voice || HangingCards.shotFit(s).fills ? .resizeAspectFill : .resizeAspect
        c.card.addSublayer(c.face)
        if s.kind == .voice {
            // a text card: a voice note is words that happened to be spoken — up to two lines of them, and a small
            // mic mark in the corner that says so
            c.title.frame = CGRect(x: 12, y: 8, width: w - 24 - 14, height: h - 14)
            c.title.contentsScale = 2
            c.title.isWrapped = true
            c.title.truncationMode = .end
            c.card.addSublayer(c.title)
            let mic = BlurtIcon.mic.makeLayer(size: 11, color: HangingCards.cardColor(BrandColor.ink, dark: isDarkMode))
            mic.name = HangingCards.voiceMicName           // style() recolours it with the appearance
            mic.position = CGPoint(x: w - 10 - 5.5, y: h - 8 - 5.5)
            c.card.addSublayer(mic)
        } else {
            // the note, on the picture's bottom edge (layoutCaption sizes it to what it says)
            // a slim band: 6 pt of soft edge, then an even dark under the one line
            c.scrim.colors = [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.6).cgColor, NSColor(white: 0, alpha: 0.66).cgColor]
            c.scrim.locations = [0, 0.28, 1]
            c.scrim.startPoint = CGPoint(x: 0.5, y: 0)
            c.scrim.endPoint = CGPoint(x: 0.5, y: 1)
            c.scrim.isHidden = true
            c.face.addSublayer(c.scrim)                  // (clipped to the card's corners with the picture)
            for line in [c.caption, c.captionStatus] {
                line.contentsScale = 2
                line.isWrapped = false
                line.truncationMode = .none
                line.isHidden = true
                line.shadowColor = NSColor.black.cgColor
                line.shadowOpacity = 0.5
                line.shadowRadius = 1.2
                line.shadowOffset = .zero
                c.card.addSublayer(line)
            }
        }
        c.badge.frame = CGRect(x: w - 6 - 31, y: h - 6 - 16, width: 31, height: 16)
        c.badge.contentsGravity = .topRight
        c.badge.contentsScale = 2
        c.card.addSublayer(c.badge)
        c.captionMarks.contentsScale = 2
        c.captionMarks.contentsGravity = .left
        c.captionMarks.isHidden = true
        c.card.addSublayer(c.captionMarks)
        // × on hover: overhanging the top-left corner (never on the picture's own dark title bar), a small disc of the
        // card's surface with a hairline — light in light mode, dark in dark (styleClose)
        c.close.frame = CGRect(x: -7, y: -7, width: 18, height: 18)
        c.close.cornerRadius = 9
        c.close.borderWidth = 0.5
        c.close.shadowColor = NSColor.black.cgColor
        c.close.shadowOpacity = 0.22
        c.close.shadowRadius = 2
        c.close.shadowOffset = CGSize(width: 0, height: 1)
        c.close.opacity = 0
        // picked (⌘-click): a neutral ring hugging the card (1.5 pt, just outside it) and the check in its corner — the
        // keyboard's accent ring sits outside that, so focus on a picked card is two rings, never ambiguous
        c.pickRing.frame = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: -2, dy: -2)
        c.pickRing.cornerRadius = c.card.cornerRadius + 2
        c.pickRing.borderWidth = 1.5
        c.pickRing.isHidden = true
        c.pickBadge.frame = CGRect(x: w - 22, y: h - 22, width: 17, height: 17)
        c.pickBadge.cornerRadius = 8.5
        c.pickBadge.borderWidth = 1.5
        c.pickBadge.borderColor = NSColor.white.cgColor
        c.pickBadge.isHidden = true
        let check = BlurtIcon.check.makeLayer(size: 10, color: NSColor.white.cgColor)
        check.position = CGPoint(x: 8.5, y: 8.5)
        c.pickBadge.addSublayer(check)
        c.copiedText.contentsScale = 2
        c.copiedText.alignmentMode = .left
        c.copied.addSublayer(c.copiedText)
        c.copiedCheck.contents = BlurtIcon.check.cgImage(size: 11, scale: 2, color: BrandColor.Island.ok.cgColor, weight: 1.2)
        c.copiedCheck.contentsGravity = .resizeAspect
        c.copied.addSublayer(c.copiedCheck)
        c.copied.cornerRadius = 11
        c.copied.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        pill(c, Loc.t("capture.card.copied", table: "Capture"))
        c.copied.opacity = 0
        c.root.addSublayer(c.card)
        c.clasp.position = CGPoint(x: c.gripX, y: -1)      // on the edge, holding it: at most 1.5 pt over the picture
        c.root.addSublayer(c.clasp)
        c.root.addSublayer(c.pickRing)
        c.root.addSublayer(c.pickBadge)
        c.root.addSublayer(c.close)
        c.root.addSublayer(c.copied)
        c.focusRing.frame = c.card.frame.insetBy(dx: -4, dy: -4)
        c.focusRing.cornerRadius = c.card.cornerRadius + 4
        c.focusRing.borderWidth = 2
        c.focusRing.isHidden = true
        c.root.addSublayer(c.focusRing)
        stage.insertSublayer(c.root, below: stackBack)
        style(c)
        return c
    }

    /// The small dark pill under a card — "Copied" (`done`: after the ok check, as every done notice), or a hint —
    /// sized to its text.
    private func pill(_ c: HangingCard, _ text: String, done: Bool = false) {
        let f = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let s = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor.white])
        let tw = ceil(s.size().width), lead: CGFloat = done ? 11 + 4 : 0
        let w = tw + lead + 24
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.copied.frame = CGRect(x: c.size.width / 2 - w / 2, y: c.size.height + 8, width: w, height: 22)
        c.copiedCheck.isHidden = !done
        c.copiedCheck.frame = CGRect(x: 12, y: 5.5, width: 11, height: 11)
        c.copiedText.frame = CGRect(x: 12 + lead, y: 3.5, width: tw + 2, height: 16)
        c.copiedText.string = s
        CATransaction.commit()
    }

    /// The hover ×: the card's own surface and hairline, its glyph in secondary ink.
    private func styleClose(_ c: HangingCard, dark: Bool) {
        c.close.backgroundColor = (dark ? NSColor(calibratedWhite: 0.27, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 1)).cgColor
        c.close.borderColor = (dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.16)).cgColor
        c.close.sublayers?.forEach { $0.removeFromSuperlayer() }
        let x = BlurtIcon.x.makeLayer(size: 9, color: (dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0.25, alpha: 1)).cgColor)
        x.position = CGPoint(x: 9, y: 9)
        c.close.addSublayer(x)
    }

    // MARK: layout

    /// Where the threads come out (the island's bottom edge, tucked in a little), in panel coordinates.
    private var threadTop: CGFloat { anchor.y - HangingCards.below - 3 }

    /// Where a card's thread comes out of the island's bottom edge (CardRow.threadX): straight above it while the row
    /// fits under the island, else the row mapped onto the edge in proportion — the threads keep their order and hang
    /// close to vertical, never a fan from the island's two corners (or from thin air beside a narrow pill).
    private func threadX(_ x: CGFloat) -> CGFloat { CardRow.threadX(x, row: row.span, edge: edge) }

    /// The part of the island's bottom edge a thread may leave from (panel x): inside its rounded corners.
    private var edge: ClosedRange<CGFloat> {
        guard let s = screen else { return 0...width }
        let f = island.frameOnScreen
        let inset = min(f.height / 2, f.width / 2)
        return (f.minX - s.frame.minX + inset)...max(f.minX - s.frame.minX + inset, f.maxX - s.frame.minX - inset)
    }

    /// The row hangs from the island's lip: some card (or the tile) is not under the island's edge, so a thread to it
    /// would run nearly flat (CardRow.rodded). Then every card hangs straight down from the lip.
    private var rodded: Bool { CardRow.rodded(centres: row.centres + (row.tileX.map { [$0] } ?? []), edge: edge) }

    /// Where the thread of a card whose clasp is at `x` starts: straight above it on the lip, or on the island's
    /// bottom edge (CardRow.threadX) when the whole row is under the island.
    private func origin(_ x: CGFloat) -> CGPoint {
        rodded ? CGPoint(x: x, y: lipY) : CGPoint(x: threadX(x), y: threadTop)
    }

    /// The island's bottom edge (panel y).
    private var islandBottom: CGFloat { anchor.y - HangingCards.below }

    /// v0.9.2 — the lip: the island grows a 3 pt band of its own black out of its bottom edge, centred on it and as wide
    /// as the outermost clasps plus 8 (CardRow.lip), with its bottom corners filled square and a small concave fillet
    /// where its sides meet the band, so island and lip read as one shape (as NotchNook's shelf and Dynamic Island's
    /// expansion keep everything in one black material). It grows out with the cards and shrinks back into the island
    /// as they reel in. No lip while the row fits under the island: each thread leaves the island itself.
    private func stepLip() {
        let items = shownCards.filter { !$0.flying }
        guard rodded, let s = screen, !items.isEmpty || !stack.isHidden else {
            lip.path = nil
            lipY = threadTop
            lipK = 0
            return
        }
        var ks = items.map { reeled($0) }
        var xs = items.map { $0.x.value - $0.size.width / 2 + $0.gripX }
        if !stack.isHidden, row.more > 0, row.more <= cards.count {
            ks.append(reeled(cards[row.more - 1]))
            xs.append(tileX.value)
        }
        lipK = ks.max() ?? 0
        let f = island.frameOnScreen
        let il = f.minX - s.frame.minX, ir = f.maxX - s.frame.minX
        guard lipK > 0.01, let full = CardRow.lip(clasps: xs, edge: edge, island: il...ir) else { lip.path = nil; lipY = threadTop; return }
        let k = Ease.outCubic(min(1, lipK))
        let l = il + (full.lowerBound - il) * k, r = ir + (full.upperBound - ir) * k
        let y0 = islandBottom, t = HangingCards.lipT
        lipY = y0 + t - 0.5
        let p = CGMutablePath()
        // the band, with round caps
        p.addRoundedRect(in: CGRect(x: l, y: y0 - 0.5, width: r - l, height: t + 0.5), cornerWidth: min(t / 2, (r - l) / 2), cornerHeight: t / 2)
        // the island's two bottom corners filled square, and a concave fillet out into the band on each side
        let rad = min(island.cornerRadiusNow, f.height / 2), fil: CGFloat = 4 * k
        for (x, dir) in [(il, CGFloat(-1)), (ir, CGFloat(1))] {
            p.addRect(CGRect(x: dir < 0 ? x : x - rad, y: y0 - rad, width: rad, height: rad + 0.5))
            if fil > 0.3 {
                let ox = x + dir * fil
                // both fillets wind the same way as the band they overlap (the layer fills non-zero: a mirrored
                // fillet wound the other way cancelled the band's top 1 pt on the right, a sliver of the screen
                // showing between the island's corner and the band)
                let q = CGMutablePath()
                if dir < 0 {
                    q.move(to: CGPoint(x: x, y: y0 - fil))
                    q.addLine(to: CGPoint(x: x, y: y0 + 0.5))
                    q.addLine(to: CGPoint(x: ox, y: y0 + 0.5))
                    q.addArc(center: CGPoint(x: ox, y: y0 - fil), radius: fil, startAngle: .pi / 2, endAngle: 0, clockwise: true)
                } else {
                    q.move(to: CGPoint(x: ox, y: y0 + 0.5))
                    q.addLine(to: CGPoint(x: x, y: y0 + 0.5))
                    q.addLine(to: CGPoint(x: x, y: y0 - fil))
                    q.addArc(center: CGPoint(x: ox, y: y0 - fil), radius: fil, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
                }
                q.closeSubpath()
                p.addPath(q)
            }
        }
        lip.path = p
        lip.opacity = Float(min(1, lipK * 1.6))
    }

    /// A card's resting top edge: under the island on the one top line, lifted while hovered.
    private func rest(_ c: HangingCard) -> CGFloat { anchor.y + c.slack - HangingCards.liftPt * c.lift.value }

    /// 0 = reeled into the island, 1 = hanging at full length (drives the reel-in's scale and fade). Measured against
    /// where the card would hang unlifted: a lifted card is fully down (v0.9.1 measured it against the lifted rest, so a
    /// hovered card came out 0.95 instead of 1.05).
    private func reeled(_ c: HangingCard) -> CGFloat {
        let top = threadTop, full = anchor.y + c.slack - top
        return full > 0 ? min(1, max(0, (c.grip.value + HangingCards.liftPt * c.lift.value - top) / full)) : 1
    }

    /// The island's centre and the cards' top edge, in panel coordinates.
    private var anchor: (x: CGFloat, y: CGFloat) {
        guard let s = screen else { return (width / 2, 60) }
        let f = island.frameOnScreen
        return (f.midX - s.frame.minX, s.frame.maxY - f.minY + HangingCards.below)
    }

    /// The cards that hang, left to right: newest first (the rest wait behind the "+N" tile).
    private var shownCards: [HangingCard] { row.shown.compactMap { $0 < cards.count ? cards[$0] : nil } }

    /// Rest x for each card (the ones that don't hang: under the tile), and the tile's x (CardRow.layout).
    private func targets() -> (xs: [CGFloat], stackX: CGFloat?) {
        row = CardRow.layout(widths: cards.map(\.size.width), tile: HangingCards.tileSize.width, gap: HangingCards.gap,
                             centre: anchor.x, bounds: HangingCards.edge...max(HangingCards.edge, width - HangingCards.edge))
        let hi = hoverCard.flatMap { h in row.shown.firstIndex { cards[$0] === h } }
        // the lifted card's neighbours make room — every item on each side, the "+N" tile included (CardRow.stepAside)
        let aside = CardRow.stepAside(items: row.shown.count + (row.tileX == nil ? 0 : 1), lifted: hi, by: HangingCards.aside)
        let tx = row.tileX.map { $0 + (aside.last ?? 0) }
        var xs = Array(repeating: tx ?? anchor.x, count: cards.count)
        for (j, i) in row.shown.enumerated() { xs[i] = row.centres[j] + aside[j] }
        return (xs, tx)
    }

    /// The cards in the order they were taken (oldest first; they hang newest first): a card put back or brought back
    /// by Undo goes back to its own place, never to the front.
    private func sortCards() {
        cards.sort { ($0.shot.wall, $0.shot.n) < ($1.shot.wall, $1.shot.n) }
    }

    /// Sync the cards with the captures (new ones appear quietly, gone ones leave).
    func refresh(quiet: Bool = false) {
        let want = snapper.cards
        // a capture that came with a project hangs only until it is pulled into the island (pullIn removes it)
        // (a take's snap, filed with the take's project, leaves with the take)
        for c in cards where !want.contains(where: { $0 === c.shot }) && dragging !== c
            && !(c.shot.assignedBy == "capture" && !c.shot.deleted && c.shot.batch?.inRecording != true) { remove(c, fall: false) }
        for s in want where !cards.contains(where: { $0.shot === s }) {
            if panel == nil { ensurePanel(on: island.screen ?? NSScreen.main ?? NSScreen.screens[0]) }
            let c = makeCard(s, x: anchor.x)
            c.opacity = 1
            cards.append(c)
        }
        sortCards()
        layout(instant: quiet)
        changed()
    }

    func layout(instant: Bool = false) {
        guard view != nil else { return }
        let t = targets()
        for (i, c) in cards.enumerated() {
            c.x.target = t.xs[i]
            if instant { c.x.snap() }
            let j = row.shown.firstIndex(of: i)
            c.slack = j.map { HangingCards.slacks[$0 % HangingCards.slacks.count] } ?? 0
            c.piled = j == nil
            c.root.zPosition = CGFloat(i)
            c.thread.zPosition = CGFloat(i) - 0.5
        }
        focus = CardFocus.clamp(focus, cards: row.shown.count, tile: row.more > 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wasHidden = stack.isHidden
        stack.isHidden = t.stackX == nil
        stackBack.isHidden = true
        if let sx = t.stackX {
            // the tile: the card surface, a second edge behind it, and how many wait there — no ghost of a picture
            // under the count (it competed with the faded text and ink of the next snap)
            // the tile: as tall as a card, narrower; the count in secondary ink and what a click does under it — a
            // quiet way into the overview, never the loudest thing in the row; a second sheet peeks out under it
            let sz = HangingCards.tileSize
            stack.bounds = CGRect(origin: .zero, size: sz)
            HangingCards.shadowAlongEdge(stack)
            if stack.isHidden != wasHidden || instant { tileX.value = sx; tileX.snap() }
            tileX.target = sx
            stack.position = CGPoint(x: tileX.value, y: stack.position.y)
            stack.anchorPoint = CGPoint(x: 0.5, y: 0)
            stackBack.bounds = CGRect(origin: .zero, size: CGSize(width: sz.width - 10, height: sz.height))
            stackBack.anchorPoint = stack.anchorPoint
            stackFace.frame = stack.bounds
            stackFace.contents = nil
            stackFace.opacity = 0
            let dark = isDarkMode
            let f = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            stackText.string = NSAttributedString(string: "+\(Loc.number(row.more))", attributes: [
                .font: f, .foregroundColor: dark ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0, alpha: 0.6)])
            stackText.frame = CGRect(x: 0, y: sz.height / 2 - 17, width: sz.width, height: 20)
            stackCaption.string = NSAttributedString(string: Loc.t("capture.cards.more_caption", table: "Capture"), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: dark ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.42)])
            stackCaption.frame = CGRect(x: 2, y: sz.height / 2 + 4, width: sz.width - 4, height: 14)
            stack.borderWidth = 0.5
            stack.borderColor = HangingCards.hairline(dark: dark).cgColor
            tileRing.isHidden = focus != row.shown.count
            tileRing.borderColor = HangingCards.cardColor(BrandColor.accent, dark: dark)
        }
        if stack.isHidden { tileRing.isHidden = true }
        stackThread.isHidden = stack.isHidden
        stackClasp.isHidden = stack.isHidden
        for (j, c) in shownCards.enumerated() {
            c.focusRing.isHidden = focus != j
            c.focusRing.borderColor = HangingCards.cardColor(BrandColor.accent, dark: isDarkMode)
        }
        for c in cards where c.piled { c.focusRing.isHidden = true }
        CATransaction.commit()
        wake()
    }

    /// How a card leaves its thread: it just fades, falls (deleted), or was taken (dragged out into another app: the
    /// card went with the drag, its thread lets go and settles back up).
    enum Leave { case fade, fall, taken }

    private func remove(_ c: HangingCard, fall: Bool) { remove(c, fall ? .fall : .fade) }

    private func remove(_ c: HangingCard, _ how: Leave) {
        guard let i = cards.firstIndex(where: { $0 === c }) else { return }
        cards.remove(at: i)
        picked.removeAll { $0 === c }
        if hoverCard === c { hoverCard = nil; tip.isHidden = true }
        if how == .taken, visible {
            // the thread's free end: still stretched after the pointer, or already sprung back into the island
            let end = c.tether.flatMap { $0.snapped == nil ? $0.end : nil } ?? origin(c.x.value - c.size.width / 2 + c.gripX)
            c.tether = nil
            c.taken = true
            c.root.opacity = 0
            c.leaving = (CACurrentMediaTime(), nil, end)
            leaving.append(c)
        } else if how == .fall, visible, !reduceMotion {
            c.leaving = (CACurrentMediaTime(), nil, c.root.position)
            leaving.append(c)
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setCompletionBlock { c.root.removeFromSuperlayer(); c.thread.removeFromSuperlayer() }
            c.root.opacity = 0
            c.thread.opacity = 0
            CATransaction.commit()
        }
        layout()
        changed()
    }

    // MARK: arrivals and departures

    /// A capture is complete: a thread drops out of the island and catches it as it flies up from `from` (a screen rect).
    /// `image`: what flies (the marked picture at full size, from an in-place markup); else the card's thumbnail.
    func catchCapture(_ s: Shot, from: NSRect?, image: CGImage? = nil) {
        let target = island.screen ?? from.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main ?? NSScreen.screens[0]
        if panel == nil || screen != target { ensurePanel(on: target) }
        // the batch's change callback may have hung it already (quietly): catch that card
        let c = cards.first { $0.shot === s } ?? makeCard(s, x: anchor.x)
        style(c)            // hung quietly before its last details were in (a voice note's heard words): what flies is current
        if !cards.contains(where: { $0 === c }) { cards.append(c) }
        sortCards()
        layout()
        if let i = cards.firstIndex(where: { $0 === c }) { c.x.value = targets().xs[i]; c.x.snap() }
        // the first card ever says what it is for, once, and hangs a little longer to say it
        let hint = CardReveal.firstHint(alreadyShown: recordConfig()["cards_hint_shown"] as? Bool ?? false,
                                       isCard: s.isCard, recording: island.isRecording)
        show(peek: hint ? 7 : 3.2)
        changed()
        if hint { DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 0.9)) { [weak self] in self?.firstHint(c) } }
        let restY = rest(c)
        if reduceMotion {
            c.grip.target = restY; c.grip.snap()
            fadeIn(c)
            return
        }
        c.flying = true
        c.grip.value = threadTop
        c.reach = (CACurrentMediaTime() + 0.15, c.grip.value, restY)   // reaches the catch point as the capture arrives
        let img = s.kind == .voice ? HangingCards.voiceSnapshot(c) : (image ?? s.markedThumb ?? s.thumb)
        if let f = from, let img = img {
            flyImage(img, from: f, to: screenRect(of: c, at: restY), springy: true, cornerRadius: c.card.cornerRadius) { [weak self] in
                self?.caught(c)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in self?.caught(c) }
        }
        wake()
    }

    private func caught(_ c: HangingCard) {
        c.flying = false
        c.opacity = 1
        c.omega += 30            // the catch sets it swaying
        c.liveUntil = CACurrentMediaTime() + 2.4      // blurt just caught it: its clasp is mint a moment, then neutral
        popClasp(c)
        wake()
        if c.pullAfterCatch {    // a capture with a project: caught, a beat, then up into the island
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.pullIn(c.shot) }
        }
    }

    /// What to do with a card, under the first one ever: "Click to copy, or drag into any app" — once the note bubble
    /// (which sits under the card) has closed, and only if the capture is still a card then (not filed with its note).
    private func firstHint(_ c: HangingCard, tries: Int = 0) {
        guard cards.contains(where: { $0 === c }), c.shot.isCard, !(recordConfig()["cards_hint_shown"] as? Bool ?? false) else { return }
        if NoteBubble.shared.isOpen || dragging != nil {
            if tries < 600 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.firstHint(c, tries: tries + 1) } }
            return
        }
        setRecordConfig("cards_hint_shown", true)
        show(peek: 6)
        pill(c, Loc.t("capture.card.first_hint", table: "Capture"))
        c.copiedUntil = CACurrentMediaTime() + 5.5
        emit(["event": "cards_first_hint", "n": c.shot.n])
        wake()
    }

    /// The clasp closing on the card: a small overshoot.
    private func popClasp(_ c: HangingCard) {
        guard !reduceMotion else { return }
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.4
        a.toValue = 1
        a.mass = 1
        a.stiffness = 420
        a.damping = 16
        a.duration = a.settlingDuration
        c.clasp.add(a, forKey: "pop")
    }

    private func fadeIn(_ c: HangingCard) {
        c.opacity = 1
        c.root.opacity = 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1; a.duration = 0.2
        c.root.add(a, forKey: "in")
        wake()
    }

    /// Assigned: the thread reels the card up into the island (0.45 s ease-in, shrinking to 0.2), which bumps.
    func pullIn(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { island.bump(); return }
        if c.flying { c.pullAfterCatch = true; return }
        if let i = cards.firstIndex(where: { $0 === c }) { cards.remove(at: i) }
        if hoverCard === c { hoverCard = nil; tip.isHidden = true }
        let a = anchor
        c.leaving = (CACurrentMediaTime(), CGPoint(x: a.x, y: a.y - HangingCards.below - island.frameOnScreen.height / 2), c.root.position)
        if !c.flying { show(peek: 1.0) }
        leaving.append(c)
        layout()
        changed()
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 0.45)) { island.bump() }
    }

    func pullInAll(_ shots: [Shot]) {
        for (i, s) in shots.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(i)) { self.pullIn(s) } }
    }

    /// Deleted: the thread lets go (and springs back up) and the card falls (0.5 s) — if it is in view; else it just goes.
    func drop(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { return }
        remove(c, fall: true)
    }

    /// Dragged out and used in another app: the card went with the drag, so only its thread lets go and settles.
    func takeAway(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { return }
        remove(c, .taken)
    }

    func update(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        style(c)
        CATransaction.commit()
        if hoverCard === c { tip.isHidden = true; tipNeed = tipContent(c) }
    }

    private func changed() {
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
        CardsOverview.shared.reload()
    }

    /// The note bubble (or a drag) keeps the cards down.
    func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        if on { show() }
        wake()
    }

    /// `sticky`: down until the pointer has come and gone (or Esc) — see `reveal()`.
    func show(peek: Double = 0, sticky: Bool = false) {
        if panel == nil { ensurePanel(on: island.screen ?? NSScreen.main ?? NSScreen.screens[0]) }
        if peek > 0 { peekUntil = max(peekUntil, CACurrentMediaTime() + peek) }
        if sticky {
            self.sticky = true
            visited = false
            revealedAt = CACurrentMediaTime()
        }
        upTillLeaves = false
        awaySince = nil
        guard !shown else { wake(); return }
        shown = true
        if styledDark != isDarkMode { restyle() }     // the appearance changed while they were up (or before launch)
        emit(["event": "cards_shown", "count": cards.count, "sticky": self.sticky, "wall": Date().timeIntervalSince1970])
        panel?.orderFrontRegardless()
        island.orderFront()                 // the island stays above the cards (the threads come out from under it)
        wake()
    }

    /// The pointer arrived on the island (or it opened): every card comes down with its detail. Pushed by the island,
    /// so it never waits for the cards' own (idle) poll.
    func islandAttention() {
        // (a voice note opens the island to listen, not to show the cards: its words show under the island)
        guard !cards.isEmpty, !island.isRecording, !VoiceInput.shared.active, !upTillLeaves else { return }
        show()
    }

    /// A recording started: the cards go up and stay there (K7: nothing hangs over what you are showing). Only ⌥H
    /// or the menu brings them down meanwhile.
    func recordingStarted() {
        sticky = false
        peekUntil = 0
        holdEsc(false)
        guard holds == 0, dragging == nil, down == nil else { return }
        retract()
    }

    /// The ear's count, ⌥H "Show hanging cards", the menu, the main window's "Unfiled captures": every card comes down
    /// and stays until the pointer has come and gone, or Esc. Nothing hanging: the island says so. ⌥H (`keyboard`)
    /// also puts the keyboard on them (see `key`).
    func reveal(via: String, keyboard: Bool = false) {
        emit(["event": "cards_reveal", "via": via, "count": cards.count])
        guard !cards.isEmpty else {
            island.toast(Loc.t("capture.cards.none", table: "Capture"), actionTitle: nil, action: nil)
            return
        }
        if let s = island.screen, s != screen, !shown, dragging == nil { ensurePanel(on: s) }
        show(sticky: true)
        if keyboard { beginKeyboard() }
    }

    /// Esc while they were brought down on purpose: up they go (and with the pointer on the island, they stay up
    /// until it has left it).
    func dismiss() {
        sticky = false
        peekUntil = 0
        holdEsc(false)
        endKeyboard()
        island.closeIfSticky()
        guard holds == 0, dragging == nil, down == nil else { return }
        retract()
        upTillLeaves = island.pointerInside
    }

    /// Esc is a system-wide hotkey only while cards brought down on purpose have the pointer on them (CardReveal.holdsEsc):
    /// an Esc meant for the app in front (stopping an agent in a terminal, closing a dialog) is never swallowed.
    private func holdEsc(_ on: Bool) {
        guard on != escHeld else { return }
        escHeld = on
        if on { registerHotkey(.cardsEsc, key: kVK_Escape, mods: 0) } else { unregisterHotkey(.cardsEsc) }
    }

    // MARK: keyboard

    /// The panel has the keyboard (⌥H): it takes keys without activating Blurt.
    private var keyboardOn = false
    private var keyboard: Bool { keyboardOn && panel?.isKeyWindow == true }

    /// The card the keyboard is on (nil: none, or the "+N" tile).
    private var focusCard: HangingCard? { focus.flatMap { $0 < row.shown.count ? shownCards[$0] : nil } }

    /// ⌥H: the keyboard on the cards, starting at the newest — ←/→ (Tab, ⇧Tab) move between the cards and the "+N"
    /// tile, ↩ or ⌘C copies the card and hands the keyboard back (on the tile: the overview, with the keyboard), ⌫
    /// deletes it (Undo in the island), Esc sends them up. Any other key, a click somewhere else or the cards going up
    /// gives the keyboard back to the app in front.
    private func beginKeyboard() {
        guard let p = panel, let v = view else { return }
        snapper.rememberFrontApp()
        p.keyable = true
        p.makeKey()
        p.makeFirstResponder(v)
        keyboardOn = true
        setFocus(CardFocus.move(nil, by: 1, cards: row.shown.count, tile: row.more > 0))
        emit(["event": "cards_keyboard", "on": true, "key": p.isKeyWindow])
    }

    /// The keyboard back to the app the user was in (`restore`; false: another of our panels takes it — the overview).
    /// Brought down by ⌥H, they now go up like any time the pointer isn't on them.
    private func endKeyboard(restore: Bool = true) {
        let had = keyboardOn
        keyboardOn = false
        panel?.keyable = false
        if focus != nil { setFocus(nil) }
        guard had else { return }
        sticky = false
        if restore, let p = panel, p.isKeyWindow {
            // resignKey() only reports a change: ordering the panel out is what gives the key status up. It is back
            // in the same moment (it can't become key now), so nothing on screen moves.
            p.orderOut(nil)
            if visible { p.orderFrontRegardless(); island.orderFront() }
            snapper.restoreFocus()
        }
        emit(["event": "cards_keyboard", "on": false])
        wake()
    }

    /// Something else took the keyboard (a click in another app, the overview): the same as handing it back.
    @objc private func panelResignedKey() {
        panel?.keyable = false
        if focus != nil { setFocus(nil) }
        if keyboardOn { keyboardOn = false; sticky = false; emit(["event": "cards_keyboard", "on": false]); wake() }
    }

    private func setFocus(_ f: Int?) {
        focus = f
        layout()
        if let c = focusCard, let e = axCards[ObjectIdentifier(c)] {
            NSAccessibility.post(element: e, notification: .focusedUIElementChanged)
        } else if f != nil, f == row.shown.count, let e = axMore {
            NSAccessibility.post(element: e, notification: .focusedUIElementChanged)
        }
    }

    /// A key while the keyboard is on the cards (true: handled).
    func key(_ e: NSEvent) -> Bool {
        let n = row.shown.count, tile = row.more > 0
        let shift = e.modifierFlags.contains(.shift), cmd = e.modifierFlags.contains(.command)
        emit(["event": "cards_key", "code": Int(e.keyCode), "focus": focus ?? -1])
        switch Int(e.keyCode) {
        case kVK_LeftArrow: setFocus(CardFocus.move(focus, by: -1, cards: n, tile: tile))
        case kVK_RightArrow: setFocus(CardFocus.move(focus, by: 1, cards: n, tile: tile))
        case kVK_Tab: setFocus(CardFocus.move(focus, by: shift ? -1 : 1, cards: n, tile: tile))
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let c = focusCard { copyAndHandBack(c) } else if tile, focus == n { openOverview(keyboard: true) }
        case kVK_ANSI_C where cmd:
            if let c = focusCard { copyAndHandBack(c) }
        case kVK_Delete, kVK_ForwardDelete:
            if let c = focusCard { snapper.delete(c.shot) }
        case kVK_Escape: dismiss()
        default:
            endKeyboard()               // typing: the keys are for the app in front, not for the cards
        }
        return true
    }

    /// ↩ / ⌘C with the keyboard on the cards: copied — and the keyboard goes straight back, so the next ⌘V pastes it
    /// where the user was; the cards stay a moment for the "Copied" to be seen, then go up unless the pointer is on them.
    private func copyAndHandBack(_ c: HangingCard) {
        guard copy(c, .click) else { return }
        endKeyboard()
        peekUntil = CACurrentMediaTime() + 0.6
        wake()
    }

    private func retract(turnable: Bool = false) {
        sticky = false
        holdEsc(false)
        endKeyboard()
        retractedAt = turnable ? NSEvent.mouseLocation : nil
        if !picked.isEmpty { setPicked([]) }           // the cards going up end a ⌘-click selection (the copy stays)
        guard shown else { return }
        shown = false
        pointerOver = false
        hoverCard?.hovered = false
        hoverCard = nil
        tip.isHidden = true
        panel?.ignoresMouseEvents = true
        emit(["event": "cards_retracted", "count": cards.count, "wall": Date().timeIntervalSince1970])
        wake()
    }

    /// Down right now (tests, the main window).
    var isShown: Bool { shown }

    /// Where a panel that opens under the cards starts (global Cocoa y, its top edge): below the strip they hang in,
    /// whether they are down now or not (BlurtCore CardRow.panelTop) — the Cards panel and its History, so a
    /// card hung back (Put Back, Undo) or brought down by the pointer never covers their title or rows; right under the
    /// island while no card hangs.
    var panelTop: CGFloat { panelTop(cardsHang: count > 0) }
    /// `cardsHang`: as if a card hung (one on its way back counts only once it has landed).
    func panelTop(cardsHang: Bool) -> CGFloat {
        let depth = CardRow.bandDepth(below: HangingCards.below, slacks: HangingCards.slacks, cardHeight: CardShape.height)
        let top = CardRow.panelTop(islandBottom: island.frameOnScreen.minY, band: depth, cardsHang: cardsHang)
        return min(top, (shownBottom ?? .greatestFiniteMagnitude) - 12)
    }

    /// The lowest edge of the cards hanging now (global Cocoa y), nil when they are up: the live transcript goes
    /// below them.
    var shownBottom: CGFloat? {
        guard shown else { return nil }
        let ys = shownCards.filter { !$0.flying }.map { screenRect(of: $0, at: $0.grip.target).minY }
        return ys.min()
    }

    func screenRect(of s: Shot) -> NSRect? {
        guard let c = cards.first(where: { $0.shot === s }) else { return nil }
        return screenRect(of: c, at: c.grip.target)
    }

    private func screenRect(of c: HangingCard, at y: CGFloat) -> NSRect {
        guard let p = panel else { return .zero }
        return NSRect(x: p.frame.minX + c.x.target - c.size.width / 2, y: p.frame.maxY - y - c.size.height, width: c.size.width, height: c.size.height)
    }

    /// The cards' sway right now (degrees; tests check Reduce Motion keeps them still).
    var swing: [CGFloat] { cards.map(\.theta) }

    /// Where every card is, for tests (global top-left points).
    func cardRects() -> [(Shot, CGRect)] { cards.compactMap { c in screenRect(of: c.shot).map { (c.shot, toCG($0)) } } }

    // MARK: animation

    private func wake() { driver?.wake() }

    /// The island changed size or place: the cards hang from under it.
    func islandMoved() {
        if let s = island.screen, s != screen, !shown, dragging == nil { ensurePanel(on: s) }
        if shown || !leaving.isEmpty { wake() }
    }

    private func frame(_ dt: CGFloat) -> Bool {
        let now = CACurrentMediaTime()
        poll(now)
        let a = anchor
        // The island grew or shrank (it opened, a toast): everything hanging moves with its bottom edge, rigidly, on
        // the island's own spring. Left to the cards' springs, a card lagged behind an island opening under it, slid
        // under the island and faded as if reeled in, then dropped out again — the flicker when the pointer came up.
        if let last = carriedY, abs(a.y - last) > 0.001 { carry(a.y - last) }
        carriedY = a.y
        let reduce = reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var moving = false
        for c in cards {
            // the thread's length: hanging when shown, reeled into the island when not
            let rest = a.y + c.slack - HangingCards.liftPt * c.lift.value
            let hiddenY = threadTop
            if let r = c.reach {
                let k = CGFloat(max(0, now - r.start) / 0.35)
                c.grip.value = r.from + (rest - r.from) * Ease.outCubic(k)
                c.grip.velocity = 0
                c.grip.target = rest
                if k >= 1 { c.reach = nil }
                moving = true
            } else {
                c.grip.target = c.dragging ? hiddenY : (shown || c.flying ? rest : hiddenY)
                if c.grip.target < c.grip.value - 0.5, !c.dragging, !shown {
                    // reeling in: an ease-in, not a spring (nothing bounces into the island)
                    c.grip.value += (c.grip.target - c.grip.value) * min(1, dt * 9)
                    c.grip.velocity = 0
                } else { _ = c.grip.step(dt) }
            }
            if reduce { c.grip.snap() }
            _ = c.x.step(dt)
            c.lift.target = c.hovered && !c.dragging ? 1 : 0
            _ = c.lift.step(dt)
            // sway: a damped pendulum on the thread; sideways motion of the thread drives it
            let restTheta: CGFloat = 0
            let drive = -c.x.velocity * 0.012
            var left = dt
            let damp: CGFloat = c.hovered ? 16 : 4.4
            while left > 0 {
                let h = min(left, 1.0 / 240)
                let acc = -46 * (c.theta - restTheta) - damp * c.omega + drive * 46
                c.omega += acc * h
                c.theta += c.omega * h
                left -= h
            }
            if reduce { c.theta = 0; c.omega = 0; c.x.snap(); c.lift.snap() }
            if !c.x.resting || !c.grip.resting || !c.lift.resting || abs(c.theta) > 0.12 || abs(c.omega) > 0.4
                || c.unreel != nil || c.tether != nil || c.flying || now < c.copiedUntil + 0.1 || now < c.liveUntil + 0.1 { moving = true }
        }
        _ = tileX.step(dt)
        if reduce { tileX.snap() }
        if !tileX.resting { moving = true }
        stepLip()
        for c in cards { place(c, now: now) }
        if row.more > 0, row.more <= cards.count, !stack.isHidden {
            // the tile hangs where the cards behind it would (they reel in and out with the others), on the same line
            let first = cards[row.more - 1]
            let y = first.grip.value + HangingCards.liftPt * first.lift.value
            stack.position = CGPoint(x: tileX.value, y: y)
            let k = reeled(first)
            stack.opacity = Float(k)
            drawThread(stackThread, from: origin(stack.position.x), to: CGPoint(x: stack.position.x, y: y - 3))
            stackClasp.position = CGPoint(x: stack.position.x, y: y - 1)
            stackClasp.opacity = Float(k)
            if stackLive != false { stackLive = false; liveClasp(stackClasp, false, dark: styledDark) }
        }
        for c in leaving { stepLeaving(c, now) }
        leaving.removeAll { c in
            guard let l = c.leaving, now - l.start > 0.55 else { return false }
            c.root.removeFromSuperlayer()
            c.thread.removeFromSuperlayer()
            return true
        }
        positionTip(now)
        CATransaction.commit()
        if HangingCards.trace { traceFrame(now) }
        if !leaving.isEmpty { moving = true }
        if tipNeed != nil, tip.isHidden, now - hoverSince < 0.6 { moving = true }
        if !visible || (!moving && !shown) {
            // reeled in: out of the way — and the display link stops first (an off-screen window's link never fires
            // again, so it would never settle into the idle polls that notice the pointer on the island)
            driver?.rest()
            panel?.orderOut(nil)
            return false
        }
        return moving || shown && (now < peekUntil)
    }

    /// The anchor's last height (see frame): each frame moves the cards by however far it went since.
    private var carriedY: CGFloat?

    private func carry(_ dy: CGFloat) {
        for c in cards {
            c.grip.value += dy
            if let r = c.reach { c.reach = (r.start, r.from + dy, r.to + dy) }
            if let t = c.tether, t.snapped != nil { c.tether = (t.end, t.snapped, CGPoint(x: t.from.x, y: t.from.y + dy)) }
        }
        for c in leaving {
            guard let l = c.leaving else { continue }
            c.leaving = (l.start, l.into.map { CGPoint(x: $0.x, y: $0.y + dy) }, CGPoint(x: l.from.x, y: l.from.y + dy))
        }
    }

    /// Scripted flicker checks (test commands only): BLURT_TRACE_CARDS=1 emits "cards_frame" whenever how much of the
    /// newest card shows changes — its opacity times the part of it below the island (0 = gone, 1 = all there).
    static let trace: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TRACE_CARDS"] == "1"
    }()
    private var tracedVis: CGFloat = -1

    private func traceFrame(_ now: CFTimeInterval) {
        guard let c = cards.last, let s = screen else { return }
        let bottom = s.frame.maxY - island.frameOnScreen.minY          // the island's bottom edge, panel coordinates
        let h = c.size.height
        let below = max(0, min(1, (c.grip.value + h - bottom) / h))
        let vis = c.flying ? 1 : CGFloat(c.root.opacity) * below
        let q = (vis * 50).rounded() / 50
        guard q != tracedVis else { return }
        tracedVis = q
        emit(["event": "cards_frame", "vis": Double(q), "shown": shown, "grip": Double(c.grip.value.rounded()),
              "island_bottom": Double(bottom.rounded()), "wall": Date().timeIntervalSince1970])
    }

    private func drawThread(_ t: CAShapeLayer, from a: CGPoint, to b: CGPoint) {
        let p = CGMutablePath()
        if hypot(b.x - a.x, b.y - a.y) > 0.5 { p.move(to: a); p.addLine(to: b) }
        t.path = p
    }

    private func place(_ c: HangingCard, now: CFTimeInterval) {
        let y = c.grip.value
        let reduce = reduceMotion
        let swing = reduce ? 0 : c.theta + c.tilt
        let gx = c.x.value - c.size.width / 2 + c.gripX
        let o = origin(gx)
        // a pendulum: the clasp sways on the thread around the point where it starts (the island's edge, the rod)
        let len = max(0, y - o.y)
        let th = (reduce ? 0 : c.theta) * .pi / 180
        let clasp = CGPoint(x: gx + len * sin(th) * 0.6, y: y)
        c.root.position = clasp
        // reeled in (hidden): the card shrinks a little and fades as it goes up into the island
        let k = reeled(c)
        var t = CATransform3DMakeRotation(swing * .pi / 180, 0, 0, 1)
        let sc = (1 + HangingCards.liftScale * c.lift.value) * (0.7 + 0.3 * k)
        t = CATransform3DScale(t, sc, sc, 1)
        c.root.transform = t
        // piled behind the stack: gone once it is under it (only the stack's own thread shows)
        let under: CGFloat = c.piled && !stack.isHidden ? 1 - min(1, abs(c.x.value - stack.position.x) / 40) : 0
        c.root.opacity = Float(c.flying || c.dragging ? 0 : c.opacity * min(1, k * 1.4) * (1 - under))
        c.thread.opacity = Float(1 - under)
        // the thread: from inside the island to the clasp — or after the dragged card, springing back once it snapped
        var end = CGPoint(x: clasp.x, y: y - 3)          // into the clasp on the card's edge
        var show: CGFloat = 1
        if let u = c.unreel {
            let f = CGFloat((now - u.start) / u.duration)
            show = Ease.outCubic(f)
            if f >= 1 { c.unreel = nil }
        }
        if let tt = c.tether {
            if let snapped = tt.snapped {
                let f = CGFloat((now - snapped) / 0.32)
                let back = Ease.outBack(f, 1.2)
                end = CGPoint(x: tt.from.x + (o.x - tt.from.x) * back, y: tt.from.y + (o.y - tt.from.y) * back)
                if f >= 1 { c.tether = nil; end = o }
            } else {
                end = tt.end
            }
        } else if c.dragging {
            end = o
        }
        drawThread(c.thread, from: o, to: CGPoint(x: o.x + (end.x - o.x) * show, y: o.y + (end.y - o.y) * show))
        c.clasp.opacity = c.dragging || show < 0.98 ? 0 : 1
        // one tight elevation at rest; the card under the pointer (or the keyboard) rises to a pop shadow
        let l = c.lift.value
        c.card.shadowRadius = 8 + 8 * l
        c.card.shadowOffset = CGSize(width: 0, height: 3 + 5 * l)
        c.card.shadowOpacity = (styledDark ? HangingCards.shadowDark : HangingCards.shadowLight) + HangingCards.shadowLift * Float(l)
        c.close.opacity = c.hovered && !c.dragging && focus == nil ? 1 : 0
        c.copied.opacity = now < c.copiedUntil ? 1 : 0
        // the note's band steps away while the card is lifted: the hover note under the row has all of it
        let band = Float(1 - min(1, l * 1.25))
        c.scrim.opacity = band
        c.caption.opacity = band
        c.captionMarks.opacity = band
        // the clasp: mint only on the card just caught (blurt in the act); hovered, focused and picked stay neutral
        let live = now < c.liveUntil
        if c.claspLive != live { c.claspLive = live; liveClasp(c.clasp, live, dark: styledDark) }
    }

    private func stepLeaving(_ c: HangingCard, _ now: CFTimeInterval) {
        guard let l = c.leaving else { return }
        let raw = CGFloat(max(0, min(1, (now - l.start) / (reduceMotion ? 0.2 : (l.into == nil ? 0.5 : 0.45)))))
        if reduceMotion {
            c.root.opacity = c.taken ? 0 : Float(1 - raw)
            c.thread.opacity = Float(1 - raw)
            return
        }
        if c.taken {
            // taken: the card is in the other app already; its thread lets go — the free end springs back up into
            // the island (a small overshoot) and fades as it settles
            c.root.opacity = 0
            let o = origin(l.from.x)
            let back = Ease.outBack(min(1, raw / 0.64), 1.2)
            drawThread(c.thread, from: o, to: CGPoint(x: l.from.x + (o.x - l.from.x) * back, y: l.from.y + (o.y - l.from.y) * back))
            c.thread.opacity = Float(1 - Ease.inCubic(raw))
            return
        }
        if let g = l.into {
            // reeled into the island: ease-in towards its centre, shrinking to 0.2; the thread shortens with it
            let k = Ease.inCubic(raw)
            let p = CGPoint(x: l.from.x + (g.x - l.from.x) * k, y: l.from.y + (g.y - l.from.y) * k)
            c.root.position = p
            let s = 1 - 0.8 * k
            c.root.transform = CATransform3DScale(CATransform3DMakeRotation(c.theta * (1 - k) * .pi / 180, 0, 0, 1), s, s, 1)
            c.root.opacity = Float(raw > 0.8 ? (1 - raw) / 0.2 : 1)
            let o = origin(p.x)
            drawThread(c.thread, from: o, to: CGPoint(x: p.x, y: max(o.y, p.y)))
        } else {
            // the thread lets go: the card drops with a turn and a fade; the empty thread springs back up
            let e = raw * raw
            let angle = c.tilt + c.theta + c.side * 28 * e
            var t = CATransform3DMakeTranslation(0, 560 * e, 0)
            t = CATransform3DRotate(t, angle * .pi / 180, 0, 0, 1)
            c.root.transform = t
            c.root.opacity = Float(1 - raw)
            c.clasp.opacity = 0                 // the clasp stays on the thread
            let back = Ease.outCubic(min(1, raw * 1.8))
            let o = origin(l.from.x)
            drawThread(c.thread, from: o, to: CGPoint(x: l.from.x + (o.x - l.from.x) * back, y: l.from.y + (o.y - l.from.y) * back))
        }
    }

    // MARK: pointer

    private var busy: Bool { holds > 0 || dragging != nil || down != nil || keyboard || CACurrentMediaTime() < peekUntil }

    /// The island stays open while the pointer is on the cards, or one is pressed or dragged.
    var holdsIsland: Bool { shown && (pointerOver || down != nil || dragging != nil) }

    /// The pointer's region (panel coordinates): the island; each hanging card (and the "+N" tile) with the strip
    /// above it up to the island, where its thread runs; and the hovered card's note — each with a small margin. Not
    /// the bounding band of the whole row: the space beside a short card (a browser's tabs) is not the cards'.
    private func hoverRegion() -> [CGRect] {
        guard let p = panel else { return [] }
        let f = island.frameOnScreen
        let isl = CGRect(x: f.minX - p.frame.minX, y: p.frame.maxY - f.maxY, width: f.width, height: f.height)
        let margin: CGFloat = 8
        var out = [isl.insetBy(dx: -10, dy: -10)]
        var rects = shownCards.filter { !$0.flying }.map { c in
            CGRect(x: c.x.value - c.size.width / 2, y: c.grip.value, width: c.size.width, height: c.size.height)
        }
        if !stack.isHidden {
            let sz = HangingCards.tileSize
            rects.append(CGRect(x: stack.position.x - sz.width / 2, y: stack.position.y, width: sz.width + 4, height: sz.height + 4))
        }
        for r in rects {
            // the card, and its thread's corridor from the island down to it (the way the pointer comes)
            out.append(r.insetBy(dx: -margin, dy: -margin))
            if r.minY > isl.maxY { out.append(CGRect(x: r.minX, y: isl.maxY, width: r.width, height: r.minY - isl.maxY).insetBy(dx: -margin, dy: 0)) }
        }
        if !tip.isHidden { out.append(tip.frame.insetBy(dx: -margin, dy: -margin)) }
        return out
    }

    /// Where the pointer was when the cards went up because it had left (nil after Esc or a recording start, which
    /// send them up for good): they turn round only if it comes back, not because they rose through where it rests.
    private var retractedAt: NSPoint?

    private func poll(_ now: CFTimeInterval) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        let onIsland = island.pointerInside
        let held = island.holdsCards           // open by a key or a command, a drawer, a drag
        let recording = island.isRecording     // only brought down on purpose while recording
        let local = NSPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        let inRegion = !cards.isEmpty && hoverRegion().contains { $0.contains(local) }
        if upTillLeaves, !onIsland { upTillLeaves = false }
        if !shown {
            pointerOver = false
            holdEsc(false)
            // the pointer resting on the island (CardReveal.dwell: a brush past drops nothing) — or back on cards still
            // on their way up: the retract turns round where they are
            let turning = visible && inRegion && (retractedAt.map { hypot($0.x - m.x, $0.y - m.y) > 2 } ?? false)
            if ((island.pointerDwelled && !upTillLeaves) || held || turning) && !cards.isEmpty && !recording { show() }
            return
        }
        let over = testHover != nil || card(at: local) != nil || (stack.isHidden == false && stack.frame.insetBy(dx: -6, dy: -6).contains(local))
            || (!tip.isHidden && tip.frame.insetBy(dx: -6, dy: -10).contains(local))
        // anywhere in the region holds the island open too (the gap under it, a card's edge)
        pointerOver = over || inRegion
        // down on purpose: until the pointer has been on the cards and left them (and the island), or Esc — or, if it
        // never came, CardReveal.unvisited after
        let pointerIn = over || inRegion || onIsland
        if sticky {
            if over { visited = true }
            if cards.isEmpty || !CardReveal.staysDown(visited: visited, pointerIn: pointerIn, sinceReveal: now - revealedAt) { sticky = false }
        }
        holdEsc(CardReveal.holdsEsc(sticky: sticky, pointerIn: pointerIn, keyboard: keyboard || CardsOverview.shared.hasKeyboard,
                                    visited: visited, sinceReveal: now - revealedAt))
        // gone CardReveal.away after the pointer has left the whole region
        if over || inRegion || busy || sticky || (!recording && (onIsland || held)) { awaySince = nil } else {
            awaySince = awaySince ?? now
            if now - awaySince! >= CardReveal.away { awaySince = nil; retract(turnable: true); return }
        }
        // the pointer's card, else the keyboard's (it lifts and shows its note the same way)
        let hit = testHover ?? (dragging == nil ? card(at: local) : nil) ?? (down == nil ? focusCard : nil)
        if hit !== hoverCard && down == nil {
            hoverCard?.hovered = false
            hoverCard = hit; tipNeed = hit.flatMap(tipContent)
            hit?.hovered = true
            hoverSince = now
            if hit == nil { tip.isHidden = true }
            layout()
        }
        // (never during a drag: the panel spans the top of the screen, and the apps under it must get the drop)
        let interactive = dragging == nil && (hit != nil || down != nil || onStack(local)
            || (!tip.isHidden && tip.frame.insetBy(dx: -4, dy: -10).contains(local)))
        if p.ignoresMouseEvents == interactive { p.ignoresMouseEvents = !interactive }
    }

    private func onStack(_ p: NSPoint) -> Bool { !stack.isHidden && shown && stack.frame.insetBy(dx: -4, dy: -4).contains(p) }

    /// A click on the "+N" tile (↩ on it, its accessibility press): every card at once, in the overview — the newest
    /// first, with the same actions as on their threads (CardsOverview.swift). The row itself never pages or rotates.
    /// `keyboard` (↩, VoiceOver): the overview takes the keyboard, on its first card — from the row, if it had it.
    func openOverview(keyboard: Bool = false) {
        guard row.more > 0 || cards.count > 0 else { return }
        emit(["event": "cards_overview", "count": cards.count, "more": row.more, "keyboard": keyboard])
        if keyboard { endKeyboard(restore: false) }
        CardsOverview.shared.show(keyboard: keyboard)
    }

    private func card(at p: NSPoint) -> HangingCard? {
        for c in shownCards.reversed() where !c.flying && !c.dragging {
            let r = CGRect(x: c.x.value - c.size.width / 2, y: c.grip.value - 8, width: c.size.width, height: c.size.height + 8).insetBy(dx: -5, dy: -4)
            if r.contains(p) { return c }
        }
        return nil
    }

    // MARK: the note under a hovered card

    private weak var tipFor: HangingCard?
    /// What the hovered card's note would add (worked out once per hover, not every frame).
    private var tipNeed: CardTip.Content?

    /// What the hovered card's note adds (CardTip): the whole note when the card cuts it short, the play button when
    /// there is a recording — nil when the card already says everything.
    /// The hover note (v0.9.1): every hovered card gets one — the rest of a note cut short and the play button of a
    /// spoken one (CardTip, only what the card can't show), then a quiet line saying what it is and when ("Snap ·
    /// 19:03"), and how to use it until a card has been used once (or, with the keyboard on the row, its keys).
    private func tipContent(_ c: HangingCard) -> CardTip.Content? {
        let playable = c.shot.voiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return CardTip.content(truncated: c.truncated && c.shot.words != nil, playable: playable) ?? CardTip.Content(text: false, play: false)
    }

    /// The user has copied or dragged out a card once: the hover note stops explaining clicks and drags.
    private lazy var cardsUsed: Bool = recordConfig()["cards_used"] as? Bool ?? false
    private func markUsed() {
        guard !cardsUsed else { return }
        cardsUsed = true
        setRecordConfig("cards_used", true)
    }

    /// The hint line under a hovered card: how to use a card, until one has been used (with the keyboard on the row the
    /// note shows the keys instead, as keycaps: KeyHint.cards).
    private func tipHintText(_ c: HangingCard) -> String? {
        cardsUsed ? nil : Loc.t("capture.card.tip_hint", table: "Capture")
    }

    /// The keyboard is on this card: the note ends with the keys (the same keycaps as the overview's footer).
    private func tipShowsKeys(_ c: HangingCard) -> Bool { focus != nil && focusCard === c }

    private func positionTip(_ now: CFTimeInterval) {
        positionSelection()
        // (it steps aside while the card says "Copied" — that sits where the note would — and while a ⌘-click
        // selection has the line under the row)
        let copying = (hoverCard?.copiedUntil ?? 0) > now
        guard let c = hoverCard, !c.dragging, now - hoverSince > 0.35, !NoteBubble.shared.isOpen, !copying,
              tipNeed != nil, picked.isEmpty else {
            if !tip.isHidden { tip.isHidden = true }
            return
        }
        if tip.isHidden || tipFor !== c || tipKeyed != (focus != nil) { buildTip(c) }
        tip.isHidden = false
        // under the whole row, never over a neighbour, centred under its card (kept on the screen)
        let w = tip.bounds.width
        let bottom = rowBottom ?? c.grip.value + c.size.height
        tip.position = CGPoint(x: min(max(c.x.value, w / 2 + 12), width - w / 2 - 12), y: bottom + 12 + tip.bounds.height / 2)
    }

    /// The lowest card edge of the row at rest (the hovered card's lift and scale not counted: the note doesn't jump).
    private var rowBottom: CGFloat? {
        let items = shownCards.filter { !$0.flying }.map { $0.grip.value + HangingCards.liftPt * $0.lift.value + $0.size.height }
        return (items + (stack.isHidden ? [] : [stack.position.y + HangingCards.tileSize.height + 4])).max()
    }

    private var tipKeyed = false

    /// The hover note (v0.9.2): one solid sheet with a clear hierarchy — the card's words in ink (all of them: the band
    /// on the card steps away meanwhile), or, for a card without words, its name ("Snap · 19:03") as the title in ink;
    /// under the words the name in secondary; then, quieter, how to use a card (tertiary) — or the keys as keycaps
    /// while the keyboard is on the row.
    private func buildTip(_ c: HangingCard) {
        tipFor = c
        tipKeyed = focus != nil
        let what = tipNeed ?? CardTip.Content(text: false, play: false)
        let dark = isDarkMode
        let ink = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.1, alpha: 1)
        let secondary = dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.55)
        let tertiary = dark ? NSColor(white: 1, alpha: 0.42) : NSColor(white: 0, alpha: 0.4)
        let text = what.text ? c.shot.words ?? "" : ""
        let meta = c.shot.plainName
        let keys = tipShowsKeys(c)
        let hint = keys ? nil : tipHintText(c)
        let tf = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let mf = NSFont.systemFont(ofSize: text.isEmpty ? 12.5 : 11, weight: text.isEmpty ? .medium : .regular)
        let hf = NSFont.systemFont(ofSize: 11)
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
        let keysImg = keys ? KeyHint.image(KeyHint.cards, dark: dark) : nil
        let keysW = keys ? KeyHint.size(KeyHint.cards).width : 0
        let pad: CGFloat = 12
        let w: CGFloat = min(320, max(text.isEmpty ? 0 : 260, width(meta, mf), hint.map { width($0, hf) } ?? 0, keysW, 46) + pad * 2)
        let attr = NSAttributedString(string: text, attributes: [.font: tf, .foregroundColor: ink])
        // at most 6 whole lines: a height between lines left a blank band above the play button once the text was cut
        let lineH = ceil(NSLayoutManager().defaultLineHeight(for: tf))
        let measured = ceil(attr.boundingRect(with: NSSize(width: w - pad * 2, height: 400), options: [.usesLineFragmentOrigin]).height)
        let th = text.isEmpty ? 0 : min(measured, 6 * lineH) + 2
        var y: CGFloat = 10
        tipText.frame = CGRect(x: pad, y: y, width: w - pad * 2, height: th)
        setText(tipText, text, font: tf, color: ink)
        if th > 0 { y += th + 4 }
        tipPlay.isHidden = !what.play
        if what.play {
            tipPlay.frame = CGRect(x: pad, y: y, width: 22, height: 22)
            if tipPlay.sublayers == nil {
                // the glyph in brand.on: white on flat mint was 1.9 : 1 (system.md §3.2)
                let play = BlurtIcon.playFill.makeLayer(size: 10, color: BrandColor.Island.on.cgColor)
                play.position = CGPoint(x: 11.6, y: 11)
                tipPlay.addSublayer(play)
            }
            y += 22 + 6
        }
        // the name: the title (ink) when there are no words, else a quiet line under them
        let mh: CGFloat = text.isEmpty ? 17 : 15
        setText(tipMeta, meta, font: mf, color: text.isEmpty ? ink : secondary)
        tipMeta.frame = CGRect(x: pad, y: y, width: w - pad * 2, height: mh)
        y += mh
        tipHint.isHidden = hint == nil
        tipKeys.isHidden = !keys
        if let h = hint {
            setText(tipHint, h, font: hf, color: tertiary)
            tipHint.frame = CGRect(x: pad, y: y + 2, width: w - pad * 2, height: 15)
            y += 17
        } else if let img = keysImg {
            tipKeys.contents = img
            tipKeys.frame = CGRect(x: pad, y: y + 7, width: keysW, height: KeyHint.capH)
            y += 7 + KeyHint.capH
        }
        tip.bounds = CGRect(x: 0, y: 0, width: w, height: y + 10)
        HangingCards.shadowAlongEdge(tip)
        emit(["event": "card_tip", "n": c.shot.n, "text": what.text, "play": what.play, "width": Double(w), "hint": hint ?? NSNull(), "keys": keys])
    }

    // MARK: the ⌘-click selection's line

    /// "2 selected · Copied" under the row while a ⌘-click selection is on (it replaces the per-card "Copied").
    private func updateSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !picked.isEmpty else { selPill.isHidden = true; return }
        let dark = isDarkMode
        var line = Loc.plural("capture.cards.selected", table: "Capture", count: picked.count)
        if pickedCopied { line += " · " + Loc.t("capture.card.copied", table: "Capture") }
        let s = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                              .foregroundColor: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.1, alpha: 1)])
        // the ok check before it once the selection is on the clipboard (a done notice, as everywhere)
        let tw = ceil(s.size().width), lead: CGFloat = pickedCopied ? 12 + 5 : 0
        let w = tw + lead + 28
        selPill.bounds = CGRect(x: 0, y: 0, width: w, height: 26)
        HangingCards.shadowAlongEdge(selPill)
        selCheck.isHidden = !pickedCopied
        selCheck.contents = BlurtIcon.check.cgImage(size: 12, scale: 2, color: HangingCards.cardColor(BrandColor.ok, dark: dark), weight: 1.2)
        selCheck.frame = CGRect(x: 14, y: 7, width: 12, height: 12)
        selText.frame = CGRect(x: 14 + lead, y: 4.5, width: tw + 2, height: 17)
        selText.string = s
        selPill.isHidden = false
    }

    private func positionSelection() {
        guard !selPill.isHidden else { return }
        let xs = picked.map(\.x.value)
        let cx = xs.isEmpty ? anchor.x : (xs.min()! + xs.max()!) / 2
        let w = selPill.bounds.width
        selPill.position = CGPoint(x: min(max(cx, w / 2 + 12), width - w / 2 - 12), y: (rowBottom ?? anchor.y + 84) + 12 + 13)
    }


    // MARK: mouse

    func mouseDown(_ e: NSEvent, at p: NSPoint) {
        let c = card(at: p)
        down = (p, c, e, false)
        if let c = c {
            let local = CGPoint(x: p.x - (c.x.value - c.size.width / 2), y: p.y - c.grip.value)
            if c.hovered, focus == nil, local.x < 12, local.y < 12 {          // × (it overhangs the top-left corner)
                down = nil
                snapper.delete(c.shot)
                return
            }
        }
        if !tip.isHidden, !tipPlay.isHidden, tip.convert(tipPlay.frame, to: stage).insetBy(dx: -6, dy: -6).contains(p),
           let u = tipFor?.shot.voiceURL {
            player = try? AVAudioPlayer(contentsOf: u)
            player?.play()
            down = nil
        }
    }

    /// A voice card dragged before its words are written down: since when the drag has waited for them.
    private var wordsWait: CFTimeInterval?

    func mouseDragged(_ e: NSEvent, at p: NSPoint) {
        guard var d = down, let c = d.card, !d.dragged, hypot(p.x - d.p.x, p.y - d.p.y) > 4 else { return }
        if c.shot.kind == .voice, c.shot.copyText == nil {
            // a voice note goes out as its words: wait for them a moment (≤ 1 s, while the pointer keeps moving),
            // else stay put and say so
            let now = CACurrentMediaTime()
            if wordsWait == nil { wordsWait = now; snapper.wantWords(c.shot) }
            guard now - wordsWait! >= 1 else { return }
            wordsWait = nil
            d.dragged = true
            down = d
            wordsNotReady(c)
            return
        }
        wordsWait = nil
        d.dragged = true
        down = d
        startDrag(c, event: d.event)
    }

    /// "The words aren't ready yet" under the card, and a small shake of its head.
    private func wordsNotReady(_ c: HangingCard) {
        pill(c, Loc.t("capture.card.words_pending", table: "Capture"))
        c.copiedUntil = CACurrentMediaTime() + 1.8
        if !reduceMotion { c.omega += 22 }
        emit(["event": "card_drag_refused", "n": c.shot.n, "reason": "no_words"])
        wake()
    }

    func mouseUp(_ e: NSEvent, at p: NSPoint) {
        defer { down = nil }
        if wordsWait != nil, let c = down?.card {     // let go while it waited for the words
            wordsWait = nil
            return wordsNotReady(c)
        }
        if let d = down, d.card == nil, !d.dragged, onStack(p), onStack(d.p) { return openOverview() }
        guard let d = down, !d.dragged, let c = d.card, c === card(at: p) else { return }
        clicked(c, count: e.clickCount, command: e.modifierFlags.contains(.command))
    }

    /// A click on a card: ⌘ = pick it; two = edit its note; one = copy it — once the double-click interval has passed
    /// with no second click (DeferredClick), so a double-click never overwrites the clipboard on its way to editing.
    private func clicked(_ c: HangingCard, count: Int, command: Bool) {
        if command, count < 2 { click.cancel(); return pick(c) }
        switch click.click(ObjectIdentifier(c), count: count, at: CACurrentMediaTime(), interval: NSEvent.doubleClickInterval) {
        case .edit:
            c.copiedUntil = 0
            emit(["event": "card_edit", "n": c.shot.n])
            NoteBubble.shared.begin(c.shot, mode: .edit)
        case .copy(let at):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at - CACurrentMediaTime())) { [weak self, weak c] in
                guard let self = self, let c = c, self.click.fire(at: CACurrentMediaTime() + 0.01) == ObjectIdentifier(c),
                      self.cards.contains(where: { $0 === c }) else { return }
                self.copy(c, .click)
            }
        }
    }

    // MARK: copy

    enum Copy: String { case click, image, text }

    /// click: the card as rich content (CardExport.copy: a shot's picture and note as HTML / RTFD / PNG / text, like
    /// a WeChat copy of a picture-and-text message; a voice card its words) · image / text: just that (the right-click
    /// menu, Recently Taken).
    static func copyShot(_ s: Shot, _ what: Copy) -> Bool {
        switch what {
        case .click: return CardExport.copy([s]) != nil
        case .image: return s.kind == .shot && s.bestURL.map { copyImageToPasteboard($0) } ?? false
        case .text:
            return s.copyText.map { t in
                let pb = capturePasteboard
                pb.clearContents()
                return pb.setString(t, forType: .string)
            } ?? false
        }
    }

    /// A copy (HangingCards.copyShot) that shows "Copied" on the card. A plain click ends a ⌘-click selection.
    @discardableResult
    func copy(_ c: HangingCard, _ what: Copy) -> Bool {
        let s = c.shot
        if what == .click { setPicked([]) }
        let ok = HangingCards.copyShot(s, what)
        guard ok else { return false }
        copied(c, Loc.t("capture.card.copied", table: "Capture"))
        emit(["event": "card_copied", "n": s.n, "what": what.rawValue,
              "types": (capturePasteboard.pasteboardItems?.first?.types ?? []).map(\.rawValue),
              "items": (capturePasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }])
        return true
    }

    private func copied(_ c: HangingCard, _ text: String) {
        pill(c, text, done: true)
        markUsed()
        c.copiedUntil = CACurrentMediaTime() + 1.2
        if c.shot.kind == .shot { c.omega += 30 }
        wake()
    }

    /// ⌘-clicked cards: a selection, copied as one — every ⌘-click adds the card (or takes it out again) and puts the
    /// whole selection on the clipboard at once, pictures and notes in the order the cards hang (newest first), like
    /// ⌘A ⌘C over a run of messages. The picked cards wear a ring in the brand colour; a plain click, or the cards going
    /// back up, ends the selection.
    private var picked: [HangingCard] = []

    func pick(_ c: HangingCard) {
        let on = !picked.contains { $0 === c }
        setPicked(on ? picked + [c] : picked.filter { $0 !== c })
        guard !picked.isEmpty else { return }
        // the line under the row says how many and that they are copied (no "Copied" pill on the card as well)
        pickedCopied = copyCards(picked, pill: nil, quiet: true)
        if pickedCopied { markUsed() }
        updateSelection()
        wake()
    }

    private func setPicked(_ cs: [HangingCard]) {
        picked = cards.reversed().filter { k in cs.contains { $0 === k } }       // the order they hang in: newest first
        if picked.isEmpty { pickedCopied = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for k in cards { stylePick(k) }
        CATransaction.commit()
        updateSelection()
        wake()
    }

    /// Picked: a neutral ink ring just outside the card and the accent check badge in its bottom-right corner — a shape
    /// twin, never only a coloured border; no mint (the clasp stays neutral), and never the keyboard's accent ring.
    private func stylePick(_ c: HangingCard) {
        let dark = isDarkMode
        c.card.borderWidth = 0.5
        c.card.borderColor = HangingCards.hairline(dark: dark).cgColor
        let on = picked.contains { $0 === c }
        c.pickRing.isHidden = !on
        c.pickBadge.isHidden = !on
        c.pickRing.borderColor = (dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.72)).cgColor
        c.pickBadge.backgroundColor = HangingCards.cardColor(BrandColor.accent, dark: dark)
    }

    /// `cs` (in this order) on the clipboard as one rich copy; "Copied N cards" on `pill`, or in the island (`quiet`:
    /// neither — the ⌘-click selection's own line says it).
    @discardableResult
    func copyCards(_ cs: [HangingCard], pill on: HangingCard?, quiet: Bool = false) -> Bool {
        guard !cs.isEmpty, let items = CardExport.copy(cs.map(\.shot)) else { return false }
        let text = cs.count == 1 ? Loc.t("capture.card.copied", table: "Capture")
                                 : Loc.plural("capture.card.copied_n", table: "Capture", count: cs.count)
        if quiet {} else if let c = on { copied(c, text) } else { island.toast(text, key: "cards_copied", icon: .check) }
        emit(["event": "card_copied", "n": cs.map(\.shot.n), "what": on == nil ? "all" : "picked",
              "items": items.map { $0.types.map(\.rawValue) }])
        return true
    }

    /// "Copy All N Cards" (a card's menu, the island's menu, the overview): every hanging card, newest first (the order
    /// they hang in), as one rich copy.
    @discardableResult
    func copyAll() -> Bool {
        setPicked([])
        return copyCards(cards.reversed().filter { $0.shot.isCard }, pill: nil)
    }

    /// `s` with the ⌘-click selection it is part of (the order they hang in), else `s` alone: what a drag onto a
    /// project, Move To ▸ and Organize take.
    func withSelection(_ s: Shot) -> [Shot] {
        let sel = picked.map(\.shot).filter(\.isCard)
        return sel.contains { $0 === s } && sel.count > 1 ? sel : [s]
    }

    /// A card's right-click menu (on its thread and in the overview): what to do with this card — Copy Image / Copy
    /// Text, Copy All N Cards, Retry Transcription (after a failure), Edit Note…, Show in Finder · Move To ▸ and
    /// Organize (this card, or its ⌘-click selection) · Delete (Undo in the island). What concerns every card at once —
    /// Organize All Cards, Delete All — is in the island's menu (islandMenuItems). `copy`: copies it with the feedback
    /// of where it was clicked.
    func cardMenu(_ s: Shot, copy: @escaping (Copy) -> Void) -> NSMenu {
        let m = NSMenu()
        if s.kind == .shot, s.bestURL != nil { m.addItem(ClosureMenuItem(Loc.t("capture.card.copy_image", table: "Capture")) { copy(.image) }) }
        if s.copyText != nil { m.addItem(ClosureMenuItem(Loc.t("capture.card.copy_text", table: "Capture")) { copy(.text) }) }
        let all = cards.filter { $0.shot.isCard }.count
        if all > 1 {
            m.addItem(ClosureMenuItem(Loc.plural("capture.card.copy_all", table: "Capture", count: all)) { [weak self] in self?.copyAll() })
        }
        if s.note.status.needsRetry {
            m.addItem(ClosureMenuItem(Loc.t("capture.card.retry_transcribe", table: "Capture")) { snapper.retryWords(s) })
        }
        m.addItem(ClosureMenuItem(Loc.t("capture.card.edit_note", table: "Capture")) { NoteBubble.shared.begin(s, mode: .edit) })
        m.addItem(ClosureMenuItem(Loc.t("capture.card.reveal", table: "Capture")) { if let u = s.bestURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } })
        m.addItem(.separator())
        // a snap taken while recording goes with the recording (its organizing run makes its item): no Move To / Organize
        if s.batch?.inRecording == true {
            let i = NSMenuItem(title: Loc.t("capture.card.in_take", table: "Capture"), action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s) })
            return m
        }
        let these = withSelection(s)
        let move = NSMenuItem(title: these.count > 1 ? Loc.plural("capture.card.move_n", table: "Capture", count: these.count)
                                                     : Loc.t("capture.card.move_to", table: "Capture"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for proj in ProjectStore.shared.projects.prefix(12) {       // recently used first
            // a folder that is gone: shown so; choosing it keeps the cards and offers Locate… (Snapper.assign)
            let gone = !proj.exists
            let i = ClosureMenuItem(proj.name) { snapper.assign(these, to: proj.id) }
            i.image = IslandGlyph.place(proj, size: 16)
            if gone {
                i.toolTip = Loc.t("capture.drawer.missing_sub", table: "Capture")
                i.setAccessibilityLabel(proj.name + ", " + T("main.sidebar.missing"))
            }
            sub.addItem(i)
        }
        if !ProjectStore.shared.projects.isEmpty { sub.addItem(.separator()) }
        let un = ClosureMenuItem(Loc.t("project.inbox")) { snapper.assign(these, to: "inbox") }
        un.image = IslandGlyph.place(nil, size: 16)
        sub.addItem(un)
        move.submenu = sub
        m.addItem(move)
        m.addItem(ClosureMenuItem(these.count > 1 ? Loc.plural("capture.card.organize_n", table: "Capture", count: these.count)
                                                  : Loc.t("capture.card.organize", table: "Capture")) { snapper.handToAI(shots: these) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s) })
        return m
    }

    /// The island's right-click menu, about every hanging card at once (TakenPanel.islandMenu puts Recently Taken under
    /// them): Show N Hanging Cards, Copy All, Organize All Cards (into the current project, or Unassigned with a
    /// suggested project each), Delete All N Cards (one Undo for all).
    func islandMenuItems() -> [(String, () -> Void)] {
        let n = count
        guard n > 0 else { return [] }
        var out: [(String, () -> Void)] = [
            (Loc.plural("capture.menu.show_cards", table: "Capture", count: n), { hanging.reveal(via: "island_menu") }),
            (Loc.plural("capture.menu.copy_cards", table: "Capture", count: n), { hanging.copyAll() }),
            (Loc.t("capture.menu.organize_all", table: "Capture"), { snapper.handToAI(project: ProjectStore.shared.organizeTarget) }),
        ]
        out.append((Loc.plural("capture.card.delete_all", table: "Capture", count: n), { snapper.deleteAllCards() }))
        return out
    }

    /// Tests: as if the pointer rested on capture N (lifted, its note under it) — nil lets the pointer decide again.
    private var testHover: HangingCard?
    func testHover(n: Int?) {
        testHover = n.flatMap { n in cards.first { $0.shot.n == n } }
        if testHover != nil { show() }
        wake()
    }

    /// Tests: copy capture N as a click / Copy Image / Copy Text would; ⌘-click it; the menu's titles for it.
    func testCopy(n: Int, _ what: Copy) -> Bool { cards.first { $0.shot.n == n }.map { copy($0, what) } ?? false }
    func testPick(n: Int) -> Bool { cards.first { $0.shot.n == n }.map { pick($0); return true } ?? false }
    var pickedNumbers: [Int] { picked.map(\.shot.n) }
    /// Tests: a ⌘-click selection of these captures, without the copy a ⌘-click also makes (no clipboard touched).
    func testSelect(_ ns: [Int]) { setPicked(cards.filter { ns.contains($0.shot.n) }) }
    func testMenu(n: Int) -> [String] {
        cards.first { $0.shot.n == n }.map { cardMenu($0.shot) { _ in }.items.filter { !$0.isSeparatorItem }.map(\.title) } ?? []
    }
    /// Tests: what a drag of capture N into an app of class `target` carries, written to `pb`.
    func testDrag(n: Int, into landing: DragLanding, to pb: NSPasteboard) -> [[String]] {
        guard let s = cards.first(where: { $0.shot.n == n })?.shot else { return [] }
        let items = CardExport.dragItems(s, into: landing)
        pb.clearContents()
        pb.writeObjects(items)
        return items.map { $0.types.map(\.rawValue) }
    }

    /// Tests (`cards …`, beside show / reveal / dismiss / all / hover): `row` = which cards hang (newest first) and the
    /// tile's count, the Esc hotkey, the keyboard; `focus` = the keyboard's stops without taking the keyboard from the
    /// app in front; `key left|right|tab|return|delete|esc|x` = that key with the keyboard on the cards; `click N [2]` =
    /// a click (or a double-click) on card N; `overview …` = CardsOverview.testCommand.
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "" {
        case "focus": setFocus(CardFocus.move(nil, by: 1, cards: row.shown.count, tile: row.more > 0))
        case "key":
            let codes = ["left": kVK_LeftArrow, "right": kVK_RightArrow, "tab": kVK_Tab, "return": kVK_Return, "delete": kVK_Delete,
                         "esc": kVK_Escape, "x": kVK_ANSI_X]
            guard a.count > 1, let code = codes[a[1]],
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: UInt16(code)) else { return }
            CardsOverview.shared.testKeyless = true      // ↩ on the tile: never the user's keyboard
            _ = key(e)
        case "click":
            if a.count > 1, let n = Int(a[1]), let c = cards.first(where: { $0.shot.n == n }) {
                clicked(c, count: 1, command: false)
                if a.count > 2, a[2] == "2" { clicked(c, count: 2, command: false) }
            }
        case "overview": CardsOverview.shared.testCommand(a.dropFirst().joined(separator: " "))
        case "row", "older", "all": break
        default: return
        }
        emit(["event": "cards_row", "shown": shownCards.map(\.shot.n), "more": row.more, "esc_held": escHeld, "sticky": sticky, "down": shown, "focus": focus ?? -1,
              "keyboard": keyboard, "tip": tip.isHidden ? NSNull() : ["for": tipFor?.shot.n ?? -1, "text": !tipText.frame.isEmpty,
                                                                      "play": !tipPlay.isHidden, "frame": [tip.frame.minX, tip.frame.minY, tip.frame.width, tip.frame.height]],
              "span": [row.span.lowerBound, row.span.upperBound], "tile_x": row.tileX ?? NSNull(),
              "threads": shownCards.map { Double(origin($0.x.target).x.rounded()) }, "lip": rodded,
              "geometry": rowGeometry()])
    }

    /// Tests and the layout lint: every hanging item's frame as drawn now (panel points, its scale included), each
    /// card's scale against its resting size, the gaps between neighbours (left to right), the lip's extent and the
    /// island's — so a lifted card that shrinks or a gap that closes up is caught by numbers, not by eye.
    func rowGeometry() -> [String: Any] {
        func r(_ f: CGRect) -> [Double] { [f.minX, f.minY, f.width, f.height].map { Double(($0 * 10).rounded() / 10) } }
        var items: [(String, CGRect, Double)] = shownCards.filter { !$0.flying }.map { c in
            ("\(c.shot.n)", c.card.convert(c.card.bounds, to: stage), Double(c.card.convert(c.card.bounds, to: stage).width / c.size.width))
        }
        if !stack.isHidden { items.append(("tile", stack.frame, Double(stack.frame.width / HangingCards.tileSize.width))) }
        items.sort { $0.1.minX < $1.1.minX }
        let gaps = zip(items.dropFirst(), items).map { Double((($0.1.minX - $1.1.maxX) * 10).rounded() / 10) }
        let f = island.frameOnScreen
        let sx = screen?.frame.minX ?? 0
        return ["items": items.map { ["id": $0.0, "frame": r($0.1), "scale": ($0.2 * 1000).rounded() / 1000] },
                "gaps": gaps, "min_gap": gaps.min() ?? NSNull(),
                "lifted": hoverCard.map { "\($0.shot.n)" } ?? NSNull(),
                "lip": lip.path.map { r($0.boundingBoxOfPath) } ?? NSNull(),
                "island": [Double(f.minX - sx), Double(f.maxX - sx)]]
    }

    func rightMouseDown(_ e: NSEvent, at p: NSPoint) {
        guard let v = view else { return }
        click.cancel()
        if onStack(p) {
            // the "+N" tile: what concerns every card
            let m = NSMenu()
            for (t, f) in islandMenuItems() { m.addItem(ClosureMenuItem(t, f)) }
            m.popUp(positioning: nil, at: p, in: v)
            return
        }
        guard let c = card(at: p) else { return }
        cardMenu(c.shot) { [weak self] what in self?.copy(c, what) }.popUp(positioning: nil, at: p, in: v)
    }

    private func startDrag(_ c: HangingCard, event: NSEvent) {
        guard let v = view else { return }
        // one dragging item per pasteboard item (the image, the note): the first shows the card, the others ride
        // under it without an image of their own (draggingFormation .none keeps them where the first is)
        let frame = NSRect(x: c.x.value - c.size.width / 2, y: c.grip.value, width: c.size.width, height: c.size.height)
        let img = NSImage(size: c.size)
        if let rep = HangingCards.snapshot(c) { img.addRepresentation(rep) }
        let drag = CardDrag(c.shot)          // its items follow the app under the pointer
        cardDrag = drag
        let dis: [NSDraggingItem] = drag.pasteboardItems().enumerated().map { i, item in
            let di = NSDraggingItem(pasteboardWriter: item)
            di.setDraggingFrame(i == 0 ? frame : NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1), contents: i == 0 ? img : nil)
            return di
        }
        click.cancel()                       // (a click just before the drag doesn't copy behind it)
        c.dragging = true                    // the thread follows the pointer, then snaps (dragMoved)
        c.tether = (CGPoint(x: c.x.value - c.size.width / 2 + c.gripX, y: c.grip.value), nil, .zero)
        dragging = c
        island.dragBegan()
        drag.setBase(image: img, frame: frame, in: v)      // a voice card's drop hint is drawn under it
        let session = v.beginDraggingSession(with: dis, event: event, source: v)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        drag.session = session
        panel?.ignoresMouseEvents = true    // the session tracks the pointer; the windows under the cards take the drop
        wake()
    }

    /// The card being dragged out: what its pasteboard holds follows the app under the pointer (CardDrag; the table
    /// is in the header). The first item also says (inside the app) which capture it is, for a drop on a project in
    /// the island.
    private var cardDrag: CardDrag?

    func dragMoved(to p: NSPoint) {
        cardDrag?.moved(to: p)
        island.dragMoved(to: p)
        guard let c = dragging, let f = panel?.frame, var t = c.tether, t.snapped == nil else { return }
        // the drag image's top edge, where the thread still holds it
        let end = CGPoint(x: p.x - f.minX, y: f.maxY - p.y - c.size.height / 2)
        let top = origin(c.x.value - c.size.width / 2 + c.gripX)
        if hypot(end.x - top.x, end.y - top.y) > (anchor.y + c.slack - top.y) + 44 || reduceMotion {
            t.snapped = CACurrentMediaTime()       // stretched as far as it goes: it snaps and springs back
            t.from = t.end
        } else {
            t.end = end
        }
        c.tether = t
        wake()
    }

    func dragEnded(at p: NSPoint, operation: NSDragOperation) {
        guard let c = dragging else { return }
        dragging = nil
        down = nil
        let drag = cardDrag
        cardDrag = nil
        let taken = island.dragEnded(at: p)
        c.dragging = false
        if taken || !c.shot.isCard {
            remove(c, fall: false)
            return
        }
        // a voice card let go of anywhere over a chat app's window: its words go into that window's composer, whether
        // the app took the drop (its message box itself) or refused it (VoiceCardDrop)
        if !ourWindow(at: p), let t = drag?.voiceTarget(at: p) {
            emit(["event": "card_taken_out", "n": c.shot.n, "operation": Int(operation.rawValue), "voice_target": t.bundleID ?? ""])
            snapper.takeOutVoice(c.shot, landed: t, at: p, accepted: !operation.isEmpty, wordsWithheld: drag?.wordsWithheld(at: t) ?? false)
            show(peek: 1.0)
            return
        }
        // dropped in another app, which took it: the card has done its job — it leaves (restorable: "Dragged out · Undo")
        if !operation.isEmpty, !ourWindow(at: p) {
            emit(["event": "card_taken_out", "n": c.shot.n, "operation": Int(operation.rawValue)])
            markUsed()
            let got = drag?.delivered(at: p)
            snapper.takeOut(c.shot, delivered: got, noteFile: got.map { drag?.noteFile($0) ?? false } ?? false,
                            landed: DropProbe.target(at: p), at: p)
            show(peek: 1.0)                  // the rest close up while you watch
            return
        }
        // back where it hung: a new thread drops out of the island and takes it
        c.tether = nil
        c.grip.target = rest(c); c.grip.snap()
        c.unreel = (CACurrentMediaTime() + (operation.isEmpty ? 0.25 : 0), 0.3)
        c.omega += operation.isEmpty ? 60 : 30
        DispatchQueue.main.asyncAfter(deadline: .now() + (operation.isEmpty ? 0.55 : 0.3)) { [weak self] in self?.popClasp(c) }
        show(peek: 1.5)
        wake()
    }

    /// Whether the window under a screen point (the one a click there would hit) is one of ours: a drop into the main
    /// window or a note is not "used in another app".
    private func ourWindow(at p: NSPoint) -> Bool {
        let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return n > 0 && NSApp.windows.contains { $0.windowNumber == n && $0 !== panel }   // (the cards take no drops)
    }

    // MARK: images of a card

    static func snapshot(_ c: HangingCard) -> NSBitmapImageRep? {
        let size = c.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let ctx = g.cgContext
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let shadow = c.card.shadowOpacity
        c.card.shadowOpacity = 0
        c.card.render(in: ctx)
        c.card.shadowOpacity = shadow
        return rep
    }

    static func voiceSnapshot(_ c: HangingCard) -> CGImage? { snapshot(c)?.cgImage }

    // MARK: accessibility

    private var axCards: [ObjectIdentifier: LayerAXElement] = [:]
    /// The "+N" tile as a button: it opens every card (the overview).
    private var axMore: LayerAXElement?

    /// The hanging cards in the order they hang (newest first), then the "+N" tile.
    func accessibilityElements() -> [LayerAXElement] {
        guard let v = view else { return [] }
        var out: [LayerAXElement] = []
        var keep: [ObjectIdentifier: LayerAXElement] = [:]
        for c in shownCards where !c.flying {
            let key = ObjectIdentifier(c)
            let e = axCards[key] ?? {
                let e = LayerAXElement.make(role: .button, layer: c.card, host: v)
                e.press = { [weak self] in self?.copy(c, .click) }
                e.setAccessibilityCustomActions(HangingCards.axActions(c.shot))
                return e
            }()
            e.setAccessibilityLabel(HangingCards.cardLabel(c.shot))
            e.setAccessibilityRoleDescription(Loc.t(c.shot.kind == .voice ? "capture.card.ax_voice" : "capture.card.ax_shot", table: "Capture"))
            e.setAccessibilityHelp(Loc.t("capture.card.ax_help", table: "Capture"))
            keep[key] = e
            out.append(e)
        }
        axCards = keep
        if row.more > 0, !stack.isHidden {
            let e = axMore ?? {
                let e = LayerAXElement.make(role: .button, layer: stack, host: v)
                e.press = { [weak self] in self?.openOverview(keyboard: true) }
                return e
            }()
            e.setAccessibilityLabel(Loc.plural("capture.cards.more_ax", table: "Capture", count: cards.count))
            axMore = e
            out.append(e)
        } else {
            axMore = nil
        }
        return out
    }

    /// A card's actions for VoiceOver (on its thread and in the overview): edit the note, move it to a project, sort it
    /// with AI, delete it.
    static func axActions(_ s: Shot) -> [NSAccessibilityCustomAction] {
        var actions = [NSAccessibilityCustomAction(name: Loc.t("capture.card.edit_note", table: "Capture")) { NoteBubble.shared.begin(s, mode: .edit); return true }]
        for p in ProjectStore.shared.projects.prefix(8) {
            let name = p.exists ? p.name : p.name + ", " + T("main.sidebar.missing")     // chosen: the card stays, Locate…
            actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.ax_move", table: "Capture", name)) { snapper.assign(s, to: p.id); return true })
        }
        actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.organize", table: "Capture")) { snapper.handToAI(shots: [s]); return true })
        actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s); return true })
        return actions
    }

    /// A card's spoken name: its words, or "Snap · 15:30" / "Voice note · 15:30" (Shot.plainName).
    static func cardLabel(_ s: Shot) -> String { s.words ?? s.plainName }
}

final class ClosureMenuItem: NSMenuItem {
    private var fn: (() -> Void)?
    convenience init(_ title: String, _ fn: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.fn = fn
        target = self
    }
    @objc func fire() { fn?() }
}

let hanging = HangingCards()
