// What the island under the notch shows for a set of capability switches (Capabilities.swift): off means gone, there
// too. BlurtApp's IslandContent.buildHome / buildDrawer and Island ask here; IslandHomeTests has the cases.
//
//   Recording & Items   the project chip, the record button, the jobs at work, Organize, the Inbox row and its "+n",
//                       the project switcher (⌥O) and the projects a card can be dropped on
//   Cards               the snap and voice-note buttons, the "N cards" row, the cards' count beside the notch, "Hang"
//                       for what another app drags onto the notch
//   Dictation, Screen Text, Phone   nothing on the open island (dictation and a voice note speak through the ears)
//
// With neither Recording nor Cards the open island would be Peep on an empty black box: it doesn't open at all then
// (`opens`). Its ears still show what Blurt is doing (a dictation, a done moment) and its toasts still come.
import Foundation

public enum IslandHome {
    public enum Button: String, Equatable, Sendable { case record, snap, voice }
    public enum Hint: String, Equatable, Sendable { case record, snap, voice, project }

    /// The open island's home, top to bottom.
    public struct Rows: Equatable, Sendable {
        /// the current project's name by Peep (it opens the switcher)
        public var projectChip: Bool
        /// the first row's buttons, left to right
        public var buttons: [Button]
        /// how many jobs at work get a row
        public var jobs: Int
        /// the cards hanging ("3 cards"): 0 = no row
        public var cards: Int
        /// …and that row's Organize button (an agent run that makes items of them)
        public var organize: Bool
        /// what waits in the Inbox: 0 = no row
        public var inbox: Int
        /// nothing going on: what the keys do
        public var hints: [Hint]

        public var isIdle: Bool { jobs == 0 && cards == 0 && inbox == 0 }
    }

    /// `jobs` / `cards` / `review`: the jobs at work, the cards hanging and the items in the Inbox, as counted.
    public static func rows(off: Set<Capability> = Capability.off, jobs: Int, cards: Int, review: Int) -> Rows {
        let recording = !off.contains(.recording), hasCards = !off.contains(.cards)
        var r = Rows(projectChip: recording,
                     buttons: (recording ? [.record] : []) + (hasCards ? [.snap, .voice] : []),
                     jobs: recording ? max(0, jobs) : 0,
                     cards: hasCards ? max(0, cards) : 0,
                     organize: recording && hasCards,
                     inbox: recording ? max(0, review) : 0,
                     hints: [])
        if r.isIdle {
            // the keys of what is on; the record key is said only when there is no snap or voice key to say first
            // (with everything on the line is as it always was: snap · voice · switch project)
            r.hints = (hasCards ? [.snap, .voice] : []) + (recording ? (hasCards ? [] : [.record]) + [.project] : [])
        }
        return r
    }

    /// The island opens (the pointer resting on it, a click, a command) only while its home has something on it.
    public static func opens(off: Set<Capability> = Capability.off) -> Bool {
        !off.contains(.recording) || !off.contains(.cards)
    }

    /// The drawer a drag opens: `hang` — the row that hangs another app's files, pictures or text as cards (and the
    /// notch takes that drag at all); `projects` — the projects, Unassigned and Organize a card can be dropped on.
    public static func drop(off: Set<Capability> = Capability.off) -> (hang: Bool, projects: Bool) {
        (!off.contains(.cards), !off.contains(.recording))
    }
}
