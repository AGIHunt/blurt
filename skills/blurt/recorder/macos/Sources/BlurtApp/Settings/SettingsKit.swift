// Shared pieces of the Settings panes and the setup assistant: the one look of every pane — SettingsPage (the pane's
// title, its groups, scrolling to a row a search or a link asked for, kept in view while the page still grows), SettingsGroup (a section:
// a secondary heading over its rows in one rounded box, System Settings' grouped form), SettingsLine (one line of a box,
// hairlines between lines), SettingRow / SettingToggle (a setting: title, ⓘ for a longer explanation and one-line
// description from SettingsCatalog on the left, the control on the right), RowPicker, InkLink —, status dots, the live permission model and its rows, config helpers, a
// project-config reader/writer.
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import BlurtCore

// MARK: - Look

enum Tone { case good, warn, bad, off }

/// A state as a small disc: good (ok, with a check: done is always a check shape, §2.3), warn (attention), bad (error),
/// off (quiet).
/// Every tone has its own shape too (system.md principle 5: a coloured state has a shape twin), so it reads in
/// grayscale and to colour-blind eyes: good a disc with a check, warn a disc with "!", bad a disc with "×", off a
/// hollow ring.
struct StatusDot: View {
    var tone: Tone
    static let size: CGFloat = 9

    var body: some View {
        let s = StatusDot.size
        Group {
            if tone == .off {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
                    .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    .overlay { mark.frame(width: s, height: s) }
            }
        }
        .frame(width: s, height: s)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        let line = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        switch tone {
        case .good:
            Path { p in
                p.move(to: CGPoint(x: 2.6, y: 4.7)); p.addLine(to: CGPoint(x: 4, y: 6.1)); p.addLine(to: CGPoint(x: 6.5, y: 3.1))
            }.stroke(Color.brandOnOk, style: line)
        case .warn:
            Path { p in
                p.move(to: CGPoint(x: 4.5, y: 2.3)); p.addLine(to: CGPoint(x: 4.5, y: 5.2))
                p.move(to: CGPoint(x: 4.5, y: 6.9)); p.addLine(to: CGPoint(x: 4.5, y: 6.95))
            }.stroke(Color(nsColor: BrandColor.onAttn), style: line)
        case .bad:
            Path { p in
                p.move(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: 6, y: 6))
                p.move(to: CGPoint(x: 6, y: 3)); p.addLine(to: CGPoint(x: 3, y: 6))
            }.stroke(Color.white, style: line)
        case .off:
            EmptyView()
        }
    }
    var color: Color {
        switch tone {
        case .good: return .brandOk
        case .warn: return .brandAttn
        case .bad: return .brandErr
        case .off: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

extension View {
    /// A selected choice (a model, a style): a brand-ink border with a brand-tint ring outside it (§3.4), never a
    /// filled card. Unselected rows get the same padding, so nothing moves when the choice changes.
    func choiceCard(_ selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return padding(.vertical, 5).padding(.horizontal, 7)
            .overlay {
                if selected {
                    shape.strokeBorder(Color.brandInk, lineWidth: 1)
                        .background(shape.stroke(Color.brandTint, lineWidth: 6))
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, -7)
    }
}

// MARK: - Page, groups, rows: the one look of every pane

enum SettingsMetrics {
    static let pageWidth: CGFloat = 680         // the column's widest; the window's extra width goes to the margins
    static let gutter: CGFloat = 28
    static let rowPadding: CGFloat = 7
    static let titleSize: CGFloat = 13
    static let detailSize: CGFloat = 12
    static let headerSize: CGFloat = 13         // a group's heading: secondary, outside its box
    static let groupGap: CGFloat = 18
    static let leadingWidth: CGFloat = 22       // an icon or a status dot before a row's title
    /// A group's rows sit in a rounded box (the grouped-form look of System Settings): its inner side inset (the row
    /// titles, the hairlines between rows), its corner radius.
    static let boxInset: CGFloat = 12
    static let boxRadius: CGFloat = 10
    /// The trailing column: every pop-up of a page the same width, so the controls share one left and one right edge.
    static let pickerWidth: CGFloat = 220
    static let ground = Color(nsColor: .controlBackgroundColor)
    /// the box on the page's ground: a few percent of ink, so it holds in light, dark and Increase Contrast alike
    static let boxFill = Color.primary.opacity(0.035)
    static let boxStroke = Color.primary.opacity(0.07)
    static let topFade: CGFloat = 10            // under the titlebar: rows scrolled up fade out instead of being cut
}

extension View {
    /// A page's ground (a pane, the search results), and under the window's transparent titlebar a band of it that
    /// fades out downwards: rows scrolled up go under it softly instead of being cut by the window's top edge.
    func settingsPageGround() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsMetrics.ground)
            .overlay(alignment: .top) {
                GeometryReader { g in
                    let top = g.safeAreaInsets.top
                    LinearGradient(stops: [.init(color: SettingsMetrics.ground, location: 0),
                                           .init(color: SettingsMetrics.ground, location: top / (top + SettingsMetrics.topFade)),
                                           .init(color: SettingsMetrics.ground.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: top + SettingsMetrics.topFade)
                        .offset(y: -top)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// A pane's page: its title (and an optional line under it), then its groups, scrolling. It scrolls to the row or the
/// section a search, a link or `show(pane: "speech/dictation")` asked for and flashes it (SettingsFlash.request).
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    var subtitle: String?
    @ViewBuilder var content: Content
    private let flash = SettingsFlash.shared         // not observed: the page only acts on a new request
    /// The row or section a request landed on, kept in view while the page still grows above it (Agents' sign-in
    /// checks come in seconds later and add lines) — else a link to the page's last section ends with it cut off.
    /// It lets go after 8 s (2 s more after each change), 20 s at most, or as soon as the user scrolls, clicks or
    /// types: never a page that jumps back under the user.
    @State private var hold: Hold?
    private struct Hold { let id: String; let anchor: UnitPoint; let since: Date; var until: Date }

    init(_ pane: SettingsPane, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // the pane's name is the window's title (in the toolbar): the page starts with its first group
                VStack(alignment: .leading, spacing: 0) {
                    if let s = subtitle {
                        Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                            .padding(.horizontal, SettingsMetrics.boxInset).padding(.top, SettingsMetrics.groupGap - 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                .padding(.horizontal, SettingsMetrics.gutter).padding(.top, -8).padding(.bottom, 24)
                .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                // (a preference doesn't come out of a ScrollView: the height is watched in place)
                .background(GeometryReader { g in Color.clear.onChange(of: g.size.height) { _ in keep(proxy) } })
            }
            .onAppear { go(proxy) }
            .onReceive(flash.$request) { _ in go(proxy) }
        }
        .settingsPageGround()
    }

    /// The page grew or shrank: the row a request landed on goes back where it was put, while the hold lasts.
    private func keep(_ proxy: ScrollViewProxy) {
        guard var h = hold else { return }
        let now = Date()
        guard now < h.until, now < h.since.addingTimeInterval(20), UserInput.shared.last < h.since else { hold = nil; return }
        proxy.scrollTo(h.id, anchor: h.anchor)
        h.until = max(h.until, now.addingTimeInterval(2))
        hold = h
    }

    /// A page that has just appeared lays itself out over a few passes (and loads into it): the scroll is repeated
    /// until that settles; a repeat where it already is moves nothing. A row that isn't shown (its condition is off)
    /// leaves the page at its section.
    private func go(_ proxy: ScrollViewProxy) {
        guard let r = flash.request, r.pane == pane.rawValue else { return }
        let section = SettingsCatalog.entry(r.id)?.section
        let anchor = section == r.id || SettingsCatalog.section(r.id) != nil ? UnitPoint.top : UnitPoint(x: 0.5, y: 0.25)
        UserInput.shared.watch()
        hold = Hold(id: r.id, anchor: anchor, since: Date(), until: Date().addingTimeInterval(8))
        for (i, delay) in [0.05, 0.2, 0.45, 0.8].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard flash.request == r else { return }
                if let s = section, s != r.id { proxy.scrollTo(s, anchor: .top) }
                proxy.scrollTo(r.id, anchor: anchor)
                if i == 0 { flash.flash(r.id) }
                if i == 3 { flash.request = nil }
            }
        }
    }
}

/// When the user last scrolled, clicked or typed in this app (SettingsPage stops keeping a row in view then).
final class UserInput {
    static let shared = UserInput()
    private(set) var last = Date.distantPast
    private var monitor: Any?
    func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            self?.last = Date()
            return e
        }
    }
}

/// Inside a group's box: rows pad their sides and draw their hairline inset; the first row's hairline is cut by the
/// box's top edge (the heading has no rule of its own).
private struct SettingsBoxedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var settingsBoxed: Bool {
        get { self[SettingsBoxedKey.self] }
        set { self[SettingsBoxedKey.self] = newValue }
    }
}

/// A section, the grouped-form look of System Settings: a small secondary heading outside (with an optional
/// accessory at its right, like a spinner or a refresh button), the rows in one rounded box with hairlines between
/// them — never under the heading —, and an optional footnote under the box. `id` is a catalogue section
/// (SettingsCatalog.sections). `disclosure`: the heading is a disclosure (Advanced) and the box shows only while it is
/// open. `boxed: false`: the rows without a box (a page's closing line, like About).
struct SettingsGroup<Content: View, Accessory: View>: View {
    var id: String?
    var title: String?
    var footer: String?
    var disclosure: Binding<Bool>?
    var boxed = true
    var accessory: Accessory
    var content: Content
    @ObservedObject private var flash = SettingsFlash.shared

    init(_ id: String, title: String? = nil, footer: String? = nil, disclosure: Binding<Bool>? = nil, boxed: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.id = id
        let t = title ?? SettingsCatalog.section(id).flatMap { SettingsCatalog.text($0.title) }
        // a section named like its page (Dictation → Dictation) needs no heading of its own under the page's title
        let named = t == SettingsCatalog.section(id).flatMap({ SettingsPane(rawValue: $0.pane)?.title })
        self.title = named || !boxed || t?.isEmpty == true ? nil : t
        self.footer = footer
        self.disclosure = disclosure
        self.boxed = boxed
        self.accessory = accessory()
        self.content = content()
    }
    /// Untitled: rows that close the page (Restore defaults).
    init(footer: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    private var open: Bool { disclosure?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = title {
                HStack(spacing: 8) {
                    if let d = disclosure {
                        Button {
                            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) {
                                d.wrappedValue.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(d.wrappedValue ? 90 : 0))
                                Text(t).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t)
                        .accessibilityValue(d.wrappedValue ? "1" : "0")
                        .accessibilityAddTraits(.isHeader)
                    } else {
                        Text(t).font(.system(size: SettingsMetrics.headerSize, weight: .semibold)).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                .frame(minHeight: 16)
                .padding(.horizontal, boxed ? SettingsMetrics.boxInset : 0)
                .padding(.bottom, 5)
                .background(FlashWash(on: id != nil && flash.row == id))
            }
            if open {
                if boxed {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .environment(\.settingsBoxed, true)
                        .padding(.horizontal, SettingsMetrics.boxInset)
                        // the first row's hairline lies on the box's top edge, where the clip takes it away
                        .padding(.top, -1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
                        .background(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous).fill(SettingsMetrics.boxFill))
                        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
                            .strokeBorder(SettingsMetrics.boxStroke, lineWidth: 0.5).allowsHitTesting(false))
                } else {
                    content
                }
                if let f = footer {
                    Text(f).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, boxed ? SettingsMetrics.boxInset : 0)
                        .padding(.top, 7)
                }
            }
        }
        .padding(.top, SettingsMetrics.groupGap)
        .id(id ?? "")
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ id: String, title: String? = nil, footer: String? = nil, disclosure: Binding<Bool>? = nil, boxed: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(id, title: title, footer: footer, disclosure: disclosure, boxed: boxed, content: content) { EmptyView() }
    }
    init(footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(footer: footer, content: content) { EmptyView() }
    }
}

/// One line of a group: the hairline above it (between rows of a box) and the row's padding. Content that isn't a
/// setting of its own (a project, a model, a permission) uses it directly; settings use SettingRow.
struct SettingsLine<Content: View>: View {
    var flashID: String?
    var padding: CGFloat = SettingsMetrics.rowPadding
    @ViewBuilder var content: Content
    @ObservedObject private var flash = SettingsFlash.shared
    @Environment(\.displayScale) private var scale

    var body: some View {
        content
            .padding(.vertical, padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)).allowsHitTesting(false)
            }
            .background(FlashWash(on: flashID != nil && flash.row == flashID))
    }
}

/// A setting: its title and one-line description on the left (from the catalogue: SettingsCatalog.entry(id)), the
/// control on the right. `title` / `detail` override the catalogue's text where it depends on state (the dictation
/// key, the chosen mode); `help` is the longer explanation (the catalogue's `more` by default), behind a small ⓘ after
/// the title that opens it in a popover — the description itself stays one line.
/// `detailBelow` puts the description under the whole row, for a wide control (the style's segmented choice).
struct SettingRow<Control: View>: View {
    let id: String
    var title: String?
    var detail: String?
    var help: String?
    var icon: String?
    var detailBelow = false
    /// a description that is a warning (a shortcut's conflict): attention ink
    var detailColor: Color?
    var control: Control
    @Environment(\.isEnabled) private var enabled

    init(_ id: String, title: String? = nil, detail: String? = nil, help: String? = nil, icon: String? = nil, detailBelow: Bool = false,
         detailColor: Color? = nil, @ViewBuilder control: () -> Control) {
        self.id = id
        self.title = title
        self.detail = detail
        self.help = help
        self.icon = icon
        self.detailBelow = detailBelow
        self.detailColor = detailColor
        self.control = control()
    }

    var entry: SettingsEntry? { SettingsCatalog.entry(id) }
    var titleText: String { title ?? entry.map(SettingsCatalog.title) ?? id }
    var detailText: String? { detail ?? entry.flatMap(SettingsCatalog.detail) }
    var helpText: String? { help ?? entry?.more.flatMap { SettingsCatalog.text($0) } }

    var body: some View {
        SettingsLine(flashID: id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 14) {
                    if let i = icon {
                        Image(systemName: i).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: SettingsMetrics.leadingWidth).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(titleText).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(enabled ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let h = helpText, !h.isEmpty { InfoButton(title: titleText, text: h) }
                        }
                        if !detailBelow, let d = detailText, !d.isEmpty { detailView(d) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    control
                }
                if detailBelow, let d = detailText, !d.isEmpty { detailView(d) }
            }
        }
        .id(id)
        .accessibilityElement(children: .contain)
    }

    private func detailView(_ d: String) -> some View {
        Text(d).font(.system(size: SettingsMetrics.detailSize))
            .foregroundStyle(detailColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(enabled ? .secondary : .tertiary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// ⓘ after a row's title: the longer explanation in a popover (a click, or Space when it has the focus), so the row
/// keeps its one-line description.
struct InfoButton: View {
    var title: String
    var text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .help(T("settings.kit.more_info"))
        .accessibilityLabel(T("settings.kit.more_info"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: SettingsMetrics.titleSize, weight: .semibold))
                Text(text).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// A setting that is a switch (native, in the app's accent).
struct SettingToggle: View {
    let id: String
    var isOn: Binding<Bool>
    var title: String?
    var detail: String?
    var help: String?

    init(_ id: String, isOn: Binding<Bool>, title: String? = nil, detail: String? = nil, help: String? = nil) {
        self.id = id
        self.isOn = isOn
        self.title = title
        self.detail = detail
        self.help = help
    }

    var body: some View {
        SettingRow(id, title: title, detail: detail, help: help) {
            Toggle(title ?? SettingsCatalog.entry(id).map(SettingsCatalog.title) ?? id, isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A menu of choices on a row's right, sized to its longest choice and flush with the column's trailing edge; `width`
/// caps it (SettingsMetrics.pickerWidth): a choice longer than that — a long project name — is cut short in the
/// button and shown whole in its menu, so one row can't stretch the column.
struct RowPicker<Value: Hashable, Choices: View>: View {
    var label: String
    var selection: Binding<Value>
    var width: CGFloat?
    @ViewBuilder var choices: Choices

    init(label: String, selection: Binding<Value>, width: CGFloat? = nil, @ViewBuilder choices: () -> Choices) {
        self.label = label
        self.selection = selection
        self.width = width
        self.choices = choices()
    }

    var body: some View {
        if let w = width {
            // its own size up to `w`, flush with the column's trailing edge; a longer choice is cut short in the button
            CapWidth(limit: w) { picker }
        } else {
            picker.fixedSize()
        }
    }

    private var picker: some View { Picker(label, selection: selection) { choices }.labelsHidden() }
}

/// Its one subview at its ideal width, but never wider than `limit` (a frame(maxWidth:) would take the whole limit and
/// leave a gap beside a short pop-up; a fixedSize() would let a long one stretch the column).
private struct CapWidth: Layout {
    var limit: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let ideal = v.sizeThatFits(.unspecified)
        return CGSize(width: min(ideal.width, limit, proposal.width ?? .infinity), height: ideal.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The brief brand wash on the row a search or a link landed on (§3.3: the selection colour), fading out. In a box
/// it reaches the box's sides.
struct FlashWash: View {
    var on: Bool
    @Environment(\.settingsBoxed) private var boxed
    var body: some View {
        RoundedRectangle(cornerRadius: boxed ? 0 : 7, style: .continuous).fill(Color.brandTint)
            .padding(.horizontal, boxed ? -SettingsMetrics.boxInset : -10)
            .opacity(on ? 1 : 0)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: on ? 0.15 : 0.7), value: on)
            .allowsHitTesting(false)
    }
}

/// A small text button in `brand.ink` (system.md §3.4: text buttons in Settings, not the system link blue).
struct InkLink: View {
    var title: String
    var action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).foregroundStyle(Color.brandInk) }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// A plain line inside a group (a condition, a how-to), without a setting of its own.
struct Hint: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// `code` in a monospaced, selectable, copyable chip.
struct CommandText: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help(T("settings.kit.copy"))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
    }
}

// MARK: - Permissions (live)

/// The four permissions as macOS reports them now (SystemAccess, simulated in test builds), refreshed while a pane or
/// the assistant shows them.
@MainActor
final class Permissions: ObservableObject {
    typealias State = SystemAccess.State
    @Published var screen: State = .notAsked
    @Published var mic: State = .notAsked
    @Published var accessibility: State = .notAsked
    /// Input Monitoring: dictation notices its key with it (with Fn, Accessibility alone does).
    @Published var inputMonitoring: State = .notAsked
    /// the 🌐 key set to "Do Nothing" (not a permission: System Settings → Keyboard), so its row updates too
    @Published var fnKey: State = .notAsked
    private var timer: Timer?
    private var observers: [Any] = []

    init() { refresh() }

    /// While a pane / the assistant shows them: once a second, and when the app comes back to the front.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func state(_ k: PermissionKind) -> State {
        switch k {
        case .screen: return screen
        case .microphone: return mic
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .fnKey: return fnKey
        }
    }

    func refresh() {
        let s = SystemAccess.state(.screen), m = SystemAccess.state(.microphone)
        let a = SystemAccess.state(.accessibility), i = SystemAccess.state(.inputMonitoring)
        if s != screen { screen = s }
        if m != mic { mic = m }
        if a != accessibility { accessibility = a }
        if i != inputMonitoring { inputMonitoring = i }
        let f = SystemAccess.state(.fnKey)
        if f != fnKey { fnKey = f }
        emitOnChange()
    }

    private var last = ""
    private func emitOnChange() {
        let sig = "\(screen.rawValue),\(mic.rawValue),\(accessibility.rawValue),\(inputMonitoring.rawValue)"
        guard sig != last else { return }
        last = sig
        emit(["event": "permissions", "screen": screen.rawValue, "mic": mic.rawValue, "accessibility": accessibility.rawValue,
              "input_monitoring": inputMonitoring.rawValue])
    }

    static var askedScreen: Bool { Config.shared["app.asked_screen"] as? Bool ?? false }

    /// The exact System Settings pane (the rows' small link).
    static func openPane(_ k: PermissionKind) { SystemAccess.openPane(k) }
}

/// The permission rows (Settings → Privacy: all four; the setup assistant: what dictation needs, without the small
/// System Settings link): live state, why in one line, and Allow — the permission guide for that one permission
/// (Blurt put in the list, the pane, the helper panel).
struct PermissionRows: View {
    @ObservedObject var p: Permissions
    var source: PermissionGuide.Source
    var kinds: [PermissionKind] = [.screen, .microphone, .accessibility, .inputMonitoring]
    var paneLink = true
    /// Settings: each one a line of its group (SettingsLine); the assistant stacks them in its box.
    var lines = false
    @ObservedObject var guide = PermissionGuide.shared

    var body: some View {
        ForEach(kinds, id: \.self) { k in
            if lines { SettingsLine { row(k, p.state(k)) } } else { row(k, p.state(k)) }
        }
    }

    /// One permission: the dot, its name and why, then one word or one button. Allowed: "Allowed" (quiet). Turned off
    /// in System Settings: "Turned off" in attention ink, and System Settings… (macOS won't ask again, so the button
    /// says where it goes). Never asked: just Allow… (the dot and the button already say it's missing; System
    /// Settings' own pane is in its menu). Not needed for what Blurt does now (Input Monitoring once Accessibility
    /// hears the dictation key): a neutral dot and "Not needed".
    func row(_ k: PermissionKind, _ st: Permissions.State) -> some View {
        let now = guide.running && guide.current == k
        let notNeeded = st != .granted && guide.satisfied(k)
        return HStack(alignment: .center, spacing: lines ? 14 : 10) {
            // granted: ok; missing: the attention dot (§3.4); not needed: neutral
            StatusDot(tone: st == .granted ? .good : notNeeded ? .off : .warn).frame(width: lines ? SettingsMetrics.leadingWidth : nil)
            VStack(alignment: .leading, spacing: lines ? 3 : 2) {
                Text(PermissionGuide.name(k)).font(lines ? .system(size: SettingsMetrics.titleSize) : .body)
                Text(PermissionGuide.why(k)).font(lines ? .system(size: SettingsMetrics.detailSize) : .caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if now {
                Text(T("settings.perm.now")).foregroundStyle(.secondary).font(.callout)
            } else if st == .granted {
                Text(T("settings.kit.allowed")).foregroundStyle(.secondary).font(.callout)
            } else if notNeeded {
                Text(T("settings.perm.not_needed")).foregroundStyle(.secondary).font(.callout)
            } else if st == .denied {
                // macOS won't ask again: the way back is System Settings, said on the button itself (the guide opens
                // the exact pane, with its helper panel beside it)
                Text(T("settings.kit.not_allowed")).foregroundStyle(Color.brandAttnInk).font(.callout)
                Button(T("settings.kit.system_settings")) { PermissionGuide.shared.start(.all, only: [k], source: source) }
                    .accessibilityIdentifier("perm.\(k).open_settings")
            } else {
                Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [k], source: source) }
                    .contextMenu {
                        if paneLink { Button(T("settings.kit.system_settings")) { Permissions.openPane(k) } }
                    }
                    .help(paneLink ? T("settings.kit.allow_help") : "")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Set Up Permissions": the guide through everything still missing, with the done line once it has run; one line of
/// its group.
struct PermissionSetupButton: View {
    var flow: PermissionFlowKind
    var source: PermissionGuide.Source
    @ObservedObject var p: Permissions
    /// the done line here (false: the pane shows it higher up)
    var banner = true
    @ObservedObject var guide = PermissionGuide.shared

    var body: some View {
        let missing = guide.missing(flow)
        let _ = p.screen                // re-evaluated as the states change
        // nothing to say (all granted, no fresh done line): no row at all, not an empty one in the form
        if (banner && guide.finished != nil) || !missing.isEmpty {
        SettingsLine {
            VStack(alignment: .leading, spacing: 6) {
                if banner { PermissionDoneBanner() }
                if !missing.isEmpty {
                    // the rows below name each one: the button alone
                    HStack(spacing: 10) {
                        Button(guide.running ? T("settings.perm.setup_running") : T("settings.perm.setup")) {
                            guide.start(flow, source: source)
                        }
                        Spacer()
                    }
                }
            }
        }
        }
    }
}

// MARK: - Config helpers

/// <repo>/.blurt/config.json, read and written whole (pretty, sorted — like _common.save_json). Read as the global
/// config.json is, on both sides (BlurtCore ConfigText.parse, _common.parse_config_text: a trailing comma forgiven).
enum ProjectConfig {
    static func url(_ ws: URL) -> URL { ws.appendingPathComponent(".blurt/config.json") }
    static func read(_ ws: URL) -> [String: Any] {
        (try? Data(contentsOf: url(ws))).flatMap(ConfigText.parse) ?? [:]
    }
    static func set(_ ws: URL, _ section: String, _ key: String, _ value: Any?) {
        var all = read(ws)
        var sec = all[section] as? [String: Any] ?? [:]
        sec[key] = value
        all[section] = sec.isEmpty ? nil : sec
        try? FileManager.default.createDirectory(at: url(ws).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url(ws), options: .atomic) }
    }
}

func isDefaultWorkspace(_ u: URL) -> Bool { u.standardizedFileURL == defaultWorkspace.standardizedFileURL }

func byteString(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false      // "0 KB", not "Zero KB"
    return f.string(fromByteCount: n)
}

/// Size of a file or a folder (recursively), on a background queue please.
func diskSize(_ u: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue { return Int64((try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) }
    var total: Int64 = 0
    let root = u.resolvingSymlinksInPath().path + "/"
    if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) {
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            else if v?.isSymbolicLink == true {
                // a link out of the folder (a Hugging Face cache whose blobs live elsewhere) counts once; links
                // inside it (snapshots → blobs) are already counted as their targets
                let t = f.resolvingSymlinksInPath()
                guard !t.path.hasPrefix(root),
                      let tv = try? t.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                      tv.isRegularFile == true else { continue }
                total += Int64(tv.totalFileAllocatedSize ?? 0)
            }
        }
    }
    return total
}
typealias CoreAgent = BlurtCore.AgentStatus   // the shell has its own AgentStatus (AgentHub.swift)
