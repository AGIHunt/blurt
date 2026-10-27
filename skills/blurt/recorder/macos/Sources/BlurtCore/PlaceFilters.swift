// The main window's filters belong to the place they were set in (Finder keeps a view per folder): the kinds and the
// State filter picked in All Items stay in All Items, and the Inbox — which has no State control — never inherits a
// "Discarded" it can't show (the dogfood's empty Inbox with a badge of 11). Saved with the window state
// ($BLURT_HOME/ui/main-window.json, "filters"), one entry per place key (Scope.key in the app); capture batches
// (session:…) are visited, not kept, so their filters aren't saved.
import Foundation

public struct PlaceFilter: Codable, Equatable {
    public var kinds: [String]
    /// nil = everything but discarded · "inbox" (needs you) · one of Lifecycle.states
    public var state: String?

    public init(kinds: [String] = [], state: String? = nil) {
        self.kinds = kinds.sorted()
        self.state = state
    }

    public var isEmpty: Bool { kinds.isEmpty && state == nil }
}

public struct PlaceFilters: Codable, Equatable {
    public private(set) var byPlace: [String: PlaceFilter] = [:]

    public init(_ byPlace: [String: PlaceFilter] = [:]) {
        for (k, f) in byPlace { set(f, for: k) }
    }

    /// Places whose filter bar has a State control. The Inbox is "what needs you" by definition, the Dictation page
    /// lists no items: a state there would hide rows with no control to say why.
    public static func showsState(_ place: String) -> Bool { place != "inbox" && place != "dictation" }
    /// Places whose filters outlive a visit (a capture batch is reached from a job or a link, then left).
    public static func remembers(_ place: String) -> Bool { !place.hasPrefix("session:") && place != "dictation" }
    /// A state value the State control offers.
    public static func isStateValue(_ s: String?) -> Bool { s == nil || s == "inbox" || Lifecycle.isState(s!) }

    /// What the place shows: its own filter, never a state it can't display.
    public func filter(for place: String) -> PlaceFilter {
        var f = byPlace[place] ?? PlaceFilter()
        if !Self.showsState(place) || !Self.isStateValue(f.state) { f.state = nil }
        return f
    }

    public mutating func set(_ f: PlaceFilter, for place: String) {
        guard Self.remembers(place) else { return }
        var f = f
        if !Self.showsState(place) || !Self.isStateValue(f.state) { f.state = nil }
        byPlace[place] = f.isEmpty ? nil : f
    }

    /// A project removed from Blurt: its filters go with it.
    public mutating func forget(_ place: String) { byPlace[place] = nil }
}
