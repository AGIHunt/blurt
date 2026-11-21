// The setup assistant's steps for a set of capability switches (Capabilities.swift; BlurtApp Onboarding.swift):
//   0  what do you want to use — the five capabilities, each with its switch (all on until one is turned off)
//   1  dictation: its key and permissions      ┐
//   2  dictation: the speech model             ├ only while Dictation is on
//   3  dictation: try it                       ┘
// With Dictation off the first step is the whole assistant (its primary is Done, "Open Blurt at login" is the footer's
// checkbox where the step dots were, so the list never moves as Dictation's switch flips). Nothing of dictation's is read before the first run's first step is answered — macOS's language files, the
// model list — and no model downloads unasked (the founder, 2026-11-21): the models step offers the recogniser with
// its size and the free space.
import Foundation

public enum OnboardingFlow {
    public static let allSteps = 4

    public static func steps(off: Set<Capability>) -> Int { off.contains(.dictation) ? 1 : allSteps }

    /// A step asked for (a resumed first run, "Set Up Speech…" from the menu) as one that exists now.
    public static func clamp(_ step: Int, off: Set<Capability>) -> Int { min(max(step, 0), steps(off: off) - 1) }

    public static func isLast(_ step: Int, off: Set<Capability>) -> Bool { step >= steps(off: off) - 1 }

    /// Dictation's own setup may start: its switch is on, and — on the first run — the user has gone past the step
    /// that asks. (Opened again later from Settings, the switch was answered long ago.)
    public static func setsUpDictation(off: Set<Capability>, firstRun: Bool, step: Int) -> Bool {
        !off.contains(.dictation) && (!firstRun || step > 0)
    }

    /// The Try-it step also teaches the card (snap → it hangs under the notch → drag it into a chat) while Cards is on.
    public static func teachesCard(off: Set<Capability>, step: Int) -> Bool {
        !off.contains(.cards) && !off.contains(.dictation) && step == allSteps - 1
    }
}
