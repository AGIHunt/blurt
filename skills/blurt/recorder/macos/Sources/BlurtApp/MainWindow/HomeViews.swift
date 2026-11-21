// Home's views (HomePage.swift has the page, its model and the keyboard). One grid for the whole column
// (SettingsMetrics): the box's edge at the column's, a glyph in an 18 pt slot 12 pt in, every text 10 pt after it —
// the capabilities' names, the lines under the box and the timeline's rows start on one vertical —, and everything
// trailing (the switches, the times) ends 12 pt before the column's edge.
import AppKit
import SwiftUI
import BlurtCore

enum HomeMetrics {
    static let inset = SettingsMetrics.boxInset
    static let slot = SettingsMetrics.iconSlot
    static let gap = SettingsMetrics.iconGap
    /// every capability's row, on or off, with a fix or without: rows never jump
    static let rowHeight: CGFloat = 56
    /// the timeline's trailing column: a time, or the row's button under the pointer
    static let timeWidth: CGFloat = 56
    static let thumb = CGSize(width: 56, height: 40)
}

struct HomeView: View {
    @ObservedObject var m: HomeModel

    var body: some View {
        FullPageFrame(title: T("home.title")) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    HomeBox(m: m)
                    if !m.waiting.isEmpty { HomeWaitingLines(m: m) }
                    if m.feed.isEmpty { HomeEmpty(m: m) } else { HomeRecent(m: m) }
                }
                // the keyboard moved somewhere out of sight: just far enough to show it
                .onChange(of: m.reveal?.seq) { _ in
                    if let s = m.reveal?.stop { proxy.scrollTo(s) }
                }
            }
        }
    }
}

// MARK: - small pieces

/// A text button in brand ink (system.md §3.3 "links"): the fix in a row, the links under the box and the timeline.
struct HomeLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }

    private struct Label: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(Color.brandInk)
                .underline(hover)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

extension View {
    /// The keyboard is here: the accent ring just outside the shape (the system's focus ring, drawn by the page
    /// because its key view holds the keyboard for every stop).
    func homeRing<S: Shape>(_ on: Bool, _ shape: S, outset: CGFloat = 2) -> some View {
        overlay {
            if on { shape.stroke(Color.brandAccent.opacity(0.6), lineWidth: 3).padding(-outset).allowsHitTesting(false) }
        }
    }
}

/// "6" in the mint pill: the count of new items (CountPill in the sidebar).
private struct NewPill: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(Color.brandOn)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(Color.brandFill))
    }
}

// MARK: - the five capabilities

struct HomeBox: View {
    @ObservedObject var m: HomeModel
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(m.rows.enumerated()), id: \.element.id) { n, row in
                if n > 0 {
                    // between rows, from the text's edge to the box's inset
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1))
                        .padding(.leading, HomeMetrics.inset + HomeMetrics.slot + HomeMetrics.gap).padding(.trailing, HomeMetrics.inset)
                }
                HomeCapabilityRow(m: m, row: row)
                    .id(HomeFeed.Stop.row(row.capability))
            }
        }
        .clipShape(shape)            // a pointed-at row's wash keeps the box's corners
        .background(shape.fill(Color.primary.opacity(scheme == .dark ? 0.045 : 0.028)))
        .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.1 : 0.07), lineWidth: 1 / max(scale, 1)).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
    }
}

struct HomeCapabilityRow: View {
    @ObservedObject var m: HomeModel
    let row: HomeRow

    var body: some View {
        let c = row.capability
        let ring = m.keyboard && m.focused
        let pointed = m.pointed == .row(c) && row.on
        let onRow = ring && m.cursor == .row(c)
        HStack(spacing: 0) {
            // the row's own target: where the capability lives
            HStack(spacing: HomeMetrics.gap) {
                Image(systemName: row.glyph).font(.system(size: 15)).foregroundStyle(row.on ? .secondary : .tertiary)
                    .frame(width: HomeMetrics.slot)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.name).font(.system(size: SettingsMetrics.titleSize, weight: .medium))
                            .foregroundStyle(row.on ? .primary : .secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .opacity(pointed || onRow ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    line
                }
                Spacer(minLength: 12)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { m.open(c) }
            .help(row.on ? (c == .screenText ? T("home.row.settings", row.name) : T("home.row.open", row.name)) : "")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(row.on ? .isButton : [])
            .accessibilityAction { m.open(c) }

            if row.on, !row.keys.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(row.keys.enumerated()), id: \.offset) { _, k in
                        KeyCaps(k.caps, size: 11).opacity(k.dim ? 0.4 : 1)
                            .help(k.tip)
                            .accessibilityLabel(k.caps.joined(separator: " ") + ", " + k.tip)
                    }
                }
                .padding(.trailing, 14)
            }
            Toggle(isOn: Binding(get: { row.on }, set: { m.set(c, on: $0) })) { EmptyView() }
                .toggleStyle(BrandSwitchStyle(label: row.name))
                .labelsHidden()
                .help(T(row.on ? "home.switch.tip.on" : "home.switch.tip.off", row.name))
                .homeRing(ring && m.cursor == .toggle(c), Capsule(style: .continuous))
                .id(HomeFeed.Stop.toggle(c))
        }
        .padding(.horizontal, HomeMetrics.inset)
        .frame(height: HomeMetrics.rowHeight)
        .background(Color.primary.opacity(pointed ? 0.03 : 0))
        .homeRing(onRow, RoundedRectangle(cornerRadius: 8, style: .continuous), outset: -3)
        .onHover { inside in
            if inside { m.pointed = .row(c) } else if m.pointed == .row(c) { m.pointed = nil }
        }
        .contextMenu {
            Button(T("home.row.settings", row.name)) { m.settings(row) }
        }
    }

    /// Under the name, a line: what it does (an off row too, dimmed), a quiet fact, or what stands in its way in
    /// attention ink — and after it the one button that fixes that. A sentence too long for the column takes a second
    /// line (the row's 56 pt hold the name and two) instead of ending in "…", the button on its last line.
    @ViewBuilder private var line: some View {
        let c = row.capability
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            // (no text: the line is its button alone — an offer, "Download more accurate speech models · 5.9 GB")
            if !row.text.isEmpty {
                Text(row.text)
                    .foregroundStyle(row.tone == .trouble ? AnyShapeStyle(Color.brandAttnInk) : AnyShapeStyle(.secondary))
                    .lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(row.tip ?? "")
            }
            if let f = row.fix {
                // after a fact a dot; after a whole sentence (the what-line ends with its full stop) just a space
                if row.text.isEmpty {
                    EmptyView()
                } else if let last = row.text.last, "。.".contains(last) {
                    Color.clear.frame(width: last == "。" ? 2 : 5, height: 1)
                } else {
                    Text(" · ").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                Button(f) { m.fix(c) }
                    .buttonStyle(HomeLinkStyle())
                    .fixedSize()
                    .homeRing(m.keyboard && m.focused && m.cursor == .fix(c), RoundedRectangle(cornerRadius: 4, style: .continuous), outset: 3)
            }
        }
        .font(.system(size: SettingsMetrics.detailSize))
    }
}

// MARK: - waiting for you

struct HomeWaitingLines: View {
    @ObservedObject var m: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(m.waiting) { w in
                HStack(spacing: HomeMetrics.gap) {
                    Image(systemName: w.glyph).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: HomeMetrics.slot)
                        .accessibilityHidden(true)
                    HStack(spacing: 0) {
                        if let n = w.pill { NewPill(count: n).padding(.trailing, 5) }
                        Text(w.text).foregroundStyle(.secondary)
                        Text(" · ").foregroundStyle(.tertiary).accessibilityHidden(true)
                        Button(w.link) { m.link(w.id) }
                            .buttonStyle(HomeLinkStyle())
                            .homeRing(m.keyboard && m.focused && m.cursor == .link(w.id), RoundedRectangle(cornerRadius: 4, style: .continuous), outset: 3)
                    }
                    .font(.system(size: SettingsMetrics.detailSize))
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 16)
                .id(HomeFeed.Stop.link(w.id))
            }
        }
        .padding(.leading, HomeMetrics.inset)
        .padding(.top, 12)
    }
}

// MARK: - recent

struct HomeRecent: View {
    @ObservedObject var m: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("home.recent")).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, HomeMetrics.inset)
                .padding(.top, 30)
            ForEach(Array(m.days.enumerated()), id: \.element.id) { n, day in
                // a day over its rows: secondary semibold, no rule, no count (the Dictation page's day headings)
                Text(DictationHistoryModel.dayTitle(day.day)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, HomeMetrics.inset)
                    .padding(.top, n == 0 ? 10 : 18).padding(.bottom, 4)
                ForEach(day.rows) { e in
                    HomeEntryRow(m: m, e: e).id(HomeFeed.Stop.entry(e.id))
                }
            }
            HStack(spacing: 18) {
                ForEach(m.closing, id: \.id) { l in
                    Button(l.title) { m.link(l.id) }
                        .buttonStyle(HomeLinkStyle())
                        .homeRing(m.keyboard && m.focused && m.cursor == .link(l.id), RoundedRectangle(cornerRadius: 4, style: .continuous), outset: 3)
                        .id(HomeFeed.Stop.link(l.id))
                }
            }
            .font(.system(size: SettingsMetrics.detailSize))
            .padding(.leading, HomeMetrics.inset + HomeMetrics.slot + HomeMetrics.gap)
            .padding(.top, 14)
        }
    }
}

/// A row of the timeline, one grammar for every kind: the mark (the app dictated into, the snap or voice-note glyph, the
/// read or translate glyph, the item's kind), a quiet line saying where it is from, what was made in up to two lines, a card's picture,
/// and the time — under the pointer the row's button instead (Copy, or Open for an item; a check for 1.2 s once copied).
struct HomeEntryRow: View {
    @ObservedObject var m: HomeModel
    let e: HomeFeed.Entry

    var body: some View {
        let stop = HomeFeed.Stop.entry(e.id)
        let selected = m.cursor == stop, pointed = m.pointed == stop, copied = m.copied == e.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        // a card's line is centred on its picture; a text row hangs from its first line
        let hasThumb = e.kind == .card && m.thumb(e.key) != nil
        HStack(alignment: hasThumb ? .center : .top, spacing: HomeMetrics.gap) {
            mark.frame(width: HomeMetrics.slot, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                if e.text.isEmpty {
                    // a snap without a note: its name is all the row says, so it is said in the text's ink
                    Text(e.source).font(.system(size: 13)).foregroundStyle(recFailed ? Color.brandAttnInk : Color.primary)
                        .lineLimit(1).frame(minHeight: 16)
                } else {
                    Text(e.source).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(recFailed ? Color.brandAttnInk : Color.secondary).lineLimit(1)
                        .frame(minHeight: 16)
                    if isFailed {
                        // not recognised, recording kept: said in the attention ink, Retry is the row's action
                        Text(m.retrying.contains(e.key) ? T("home.entry.retrying") : e.text).font(.system(size: 13))
                            .foregroundStyle(Color.brandAttnInk).lineLimit(1)
                    } else {
                        Text(e.text).font(.system(size: 13)).lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 12)
            if e.kind == .card, let t = m.thumb(e.key) {
                Image(decorative: t, scale: 1).resizable().interpolation(.high)
                    .frame(width: HomeMetrics.thumb.width, height: HomeMetrics.thumb.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
            ZStack(alignment: hasThumb ? .trailing : .topTrailing) {
                Text(DictationHistoryModel.time(e.time)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(minHeight: 16)
                    .opacity(pointed || copied ? 0 : 1)
                if pointed || copied {
                    Button { m.primary(e.id) } label: {
                        ZStack {
                            Text(action).opacity(copied ? 0 : 1)
                            if copied {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.brandOk)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .offset(y: hasThumb ? 0 : -3)
                    .help(copied ? T("main.dictation.copied") : action)
                    .accessibilityLabel(copied ? T("main.dictation.copied") : action)
                }
            }
            .frame(width: HomeMetrics.timeWidth, alignment: hasThumb ? .trailing : .topTrailing)
        }
        .padding(.horizontal, HomeMetrics.inset).padding(.vertical, hasThumb ? 5 : 7)
        .background(shape.fill(selected ? (m.focused ? Color.brandTint : Color.primary.opacity(0.06)) : Color.primary.opacity(pointed ? 0.035 : 0)))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { m.primary(e.id) })
        .simultaneousGesture(TapGesture().onEnded { m.select(stop, keyboard: false) })
        .onHover { inside in
            if inside { m.pointed = stop } else if m.pointed == stop { m.pointed = nil }
        }
        .contextMenu {
            if let r = rec {
                // what the recording's row offers in its state, Dismiss last on its own
                let acts = Recordings.actions(r, agent: m.recAgent)
                ForEach(acts.filter { $0 != .dismiss }, id: \.self) { a in Button(RecordingLook.label(a, r)) { RecordingLook.run(a, r) } }
                if acts.contains(.dismiss) {
                    Divider()
                    Button(RecordingLook.label(.dismiss)) { RecordingLook.run(.dismiss, r) }
                }
            } else {
                Button(action) { m.select(stop, keyboard: false); m.primary(e.id) }
                if e.kind == .item { Button(T("home.entry.copy_title")) { m.copy(e.id) } }
                Divider()
                Button(all.title) { m.link(all.id) }
            }
        }
        .help(rec.flatMap(RecordingLook.stateDetail) ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { m.primary(e.id) }
        .accessibilityAction(named: action) { m.copy(e.id) }
    }

    private var isFailed: Bool { e.kind == .dictation && m.failed.contains(e.key) }
    private var rec: Recordings.Row? { e.kind == .recording ? m.recordings[e.key] : nil }
    /// a recording whose organising didn't finish: its quiet line in the attention ink
    private var recFailed: Bool { if case .failed? = rec?.state { return true } else { return false } }

    private var action: String {
        if let r = rec { return RecordingLook.homeAction(r, agent: m.recAgent).map { RecordingLook.label($0, r) } ?? T("home.entry.open") }
        return isFailed ? T("home.entry.retry") : e.kind == .item ? T("home.entry.open") : T("dictation.history.copy")
    }

    private var all: (id: String, title: String) {
        switch e.kind {
        case .dictation: return ("all.dictation", T("home.all.dictation"))
        case .card: return ("all.cards", T("home.all.cards"))
        case .screenText: return ("all.screen_text", T("home.all.screen_text"))
        case .recording, .item: return ("all.items", T("home.all.items"))
        }
    }

    @ViewBuilder private var mark: some View {
        switch e.kind {
        case .dictation:
            DictationAppIcon(bundle: m.dictations[e.key]?.bundle, name: e.source, size: 16)
        case .card:
            Image(nsImage: (m.shots[e.key]?.kind == .voice ? BlurtIcon.mic : BlurtIcon.snap).image(size: 15))
                .renderingMode(.template).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .screenText:
            ScreenTextMark(translated: m.screenTexts[e.key]?.translated ?? false)
        case .recording:
            Image(nsImage: Look.symbol("video", T("main.rec.kind"), size: 13) ?? NSImage())
                .renderingMode(.template).foregroundStyle(.secondary).accessibilityHidden(true)
        case .item:
            Image(nsImage: Look.kindImage(m.items[e.key]?.kind ?? "note", size: 16)).accessibilityHidden(true)
        }
    }
}

// MARK: - nothing made yet

/// Peep, and per capability that is on the one thing to try, its key in the sentence. Dictation that can't run yet
/// says its fix instead of a promise.
struct HomeEmpty: View {
    @ObservedObject var m: HomeModel

    var body: some View {
        let tries = m.tries
        VStack(spacing: 0) {
            MascotImage(clip: .idle, size: 64).frame(width: 64, height: 64).accessibilityHidden(true)
            Text(T(tries.isEmpty && !m.rows.contains(where: \.on) ? "home.empty.all_off" : "home.empty.title"))
                .font(.system(size: EmptyState.titleSize, weight: .semibold))
                .padding(.top, EmptyState.markToTitle)
            if !tries.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(tries) { t in
                        HStack(spacing: 4) {
                            if let trouble = t.trouble {
                                Text(trouble).foregroundStyle(Color.brandAttnInk)
                                if let f = t.fix {
                                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                                    Button(f) { m.fix(t.capability) }.buttonStyle(HomeLinkStyle())
                                }
                            } else {
                                if !t.before.isEmpty { Text(t.before) }
                                if !t.caps.isEmpty { KeyCaps(t.caps, size: 11) }
                                if !t.after.isEmpty { Text(t.after) }
                            }
                        }
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(minHeight: 19)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }
}
