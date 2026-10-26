// Peep, the brand character, as plain numbers so they can be tested: which frame of a clip shows at a moment, which
// talking frame says a voice level, the still each clip rests on with Reduce Motion, and which state the menu-bar
// glyph is in. The frames themselves are renders from the Peep release package (assets/brand/import_peep.py →
// Sources/BlurtApp/Resources/Peep/peep.json); BlurtApp's Mascot.swift and MenuGlyph.swift play them.
import Foundation

public enum PeepState: String, CaseIterable, Sendable {
    /// a breath and a blink (loops, with a short random hold between loops so blinks never line up)
    case idle
    /// turns to you, two blinks (launch, the onboarding's first step)
    case hello
    /// eye wide, swelling with the voice (the countdown, a voice note)
    case listening
    /// the beak moves with the words (dictation; driven by the voice level where there is one)
    case talking
    /// the eye looks round (transcribing, organising)
    case thinking
    /// a peep and a hop (sent, saved, sorted, a job done)
    case done
    /// a head shake, then a droop (only real failures)
    case error

    public var loops: Bool {
        switch self {
        case .idle, .listening, .talking, .thinking: return true
        case .hello, .done, .error: return false
        }
    }
}

/// One clip as the package has it: `frames` at `fps`.
public struct PeepClip: Equatable, Sendable {
    public let frames: Int
    public let fps: Double
    /// talking only: how far the beak is open in each frame (any unit, larger = wider)
    public let open: [Double]
    public init(frames: Int, fps: Double, open: [Double] = []) {
        self.frames = max(1, frames)
        self.fps = fps > 0 ? fps : 30
        self.open = open
    }
    public var duration: Double { Double(frames) / fps }
}

public enum PeepPlayback {
    /// The frame at `t` seconds from the clip's start: a loop wraps, a one-shot holds its last frame.
    public static func frame(at t: Double, clip: PeepClip, loops: Bool) -> Int {
        let i = Int((max(0, t) * clip.fps).rounded(.down))
        return loops ? i % clip.frames : min(i, clip.frames - 1)
    }

    /// The moment a clip shows with Reduce Motion (and in pictures of it), as a fraction of the clip: the state said in
    /// one frame — the eye up while thinking, the beak half open while talking, the happy eye after the peep, the droop.
    public static func stillFraction(_ s: PeepState) -> Double {
        switch s {
        case .idle, .hello: return 0
        case .listening: return 0.4
        case .talking: return 0.29       // a beat with the beak well open (peep.py: 34° at frame 12 of 42)
        case .thinking: return 0.22      // eyes up-left
        case .done: return 0.62          // the happy closed eye, landed
        case .error: return 0.62         // the droop
        }
    }

    public static func stillFrame(_ s: PeepState, clip: PeepClip) -> Int {
        min(clip.frames - 1, Int((stillFraction(s) * Double(clip.frames)).rounded(.down)))
    }

    /// Talking driven by a voice level (0…1): the frame whose beak opening is nearest the level mapped onto the clip's
    /// range — silence shows the most shut frame, a loud word the widest. Without openings: the clip's own timing.
    public static func talkingFrame(level: Double, clip: PeepClip) -> Int {
        guard clip.open.count == clip.frames, let lo = clip.open.min(), let hi = clip.open.max(), hi > lo else { return 0 }
        let l = min(1, max(0, level))
        // a soft knee: quiet speech already moves the beak a little, shouting does not pin it open
        let target = lo + (hi - lo) * pow(l, 0.7)
        var best = 0, gap = Double.infinity
        for (i, o) in clip.open.enumerated() where abs(o - target) < gap {
            best = i
            gap = abs(o - target)
        }
        return best
    }

    /// A level that opens fast and closes a little slower, as a beak would (per tick of `dt` seconds).
    public static func smooth(_ current: Double, toward level: Double, dt: Double) -> Double {
        let rate = level > current ? 18.0 : 7.0
        return current + (level - current) * min(1, rate * max(0, dt))
    }

    /// The hold before the next idle loop (so blinks never line up across Peeps, and the island's Peep is not a
    /// metronome): 0–2 s, from `random` in 0…1.
    public static func idleHold(random: Double) -> Double { 2 * min(1, max(0, random)) }
}

/// What the menu-bar glyph shows, from what the app is doing (MenuGlyph.sync). A one-shot (done, error) plays over any
/// of these and then hands back.
public enum PeepGlyphMode: String, Equatable, Sendable {
    case idle, listening, talking, thinking

    /// dictating → talking (the beak with the voice); a voice note or the countdown → listening; transcribing or
    /// organising → thinking; otherwise idle (a blink now and then).
    public static func from(dictating: Bool, voiceNote: Bool, countdown: Bool, transcribing: Bool, organizing: Bool) -> PeepGlyphMode {
        if dictating { return .talking }
        if voiceNote || countdown { return .listening }
        if transcribing || organizing { return .thinking }
        return .idle
    }

    public var state: PeepState {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .talking: return .talking
        case .thinking: return .thinking
        }
    }
}
