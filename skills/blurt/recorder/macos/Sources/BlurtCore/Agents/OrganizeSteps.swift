// Which step of an organising run (process job: prepare → transcribe → write → frames) a failure belongs to. The whole
// agent runs under "transcribe" (it transcribes, writes and picks frames itself), so a failure used to be blamed on
// transcription even when the agent couldn't sign in, ran out of quota or had no network. Now:
//   auth / quota / network / model   → the agent itself couldn't work: preparing it failed (whether or not a
//                                      transcript is already there — Retry, a fallback after a partial run — it
//                                      says done then, and writing is left as not run)
//   a transcript was written         → transcription is done; writing the items failed
//   anything else                    → the step it was in (transcribe) failed, as before
import Foundation

public enum OrganizeSteps {
    /// Failure classes that are about the agent, not the recording (agents.json failures).
    public static let agentLevel: Set<String> = ["auth", "quota", "network", "model"]

    /// The step states to set before the job finishes as failed (finish closes what is still running as failed and
    /// what is still pending as skipped).
    public static func onFailure(failureClass: String?, transcribed: Bool) -> [(step: String, state: StepState)] {
        if let c = failureClass, agentLevel.contains(c) {
            return [("transcribe", transcribed ? .done : .pending), ("prepare", .failed)]
        }
        if transcribed { return [("transcribe", .done), ("write", .failed)] }
        return [("transcribe", .failed)]
    }

    /// An organising run that wrote its batch with no item in it is a failure when the recording's words were expected
    /// and never arrived: no transcript.json, so the agent had nothing to read and filed nothing. That used to end as
    /// "done, 0 items" (2026-11-19, #107: on a Mac without ffmpeg, `transcribe.py run` stopped on the missing ffprobe
    /// and the agent went on to an empty batch). A few captures, a shots session and a video kept without its mic have
    /// no words to miss.
    public static func emptyBatchFailed(captures: Bool, shots: Bool, videoOnly: Bool, transcribed: Bool) -> Bool {
        !captures && !shots && !videoOnly && !transcribed
    }

    /// The tool a script in the run couldn't find, and how its own line says to install it (transcribe.py →
    /// _common.ffmpeg_bin): ("ffprobe", "brew install ffmpeg") from "ERROR: ffprobe not found on PATH. Install it
    /// first: brew install ffmpeg". nil when the run's output has no such line.
    public static func missingTool(in output: String) -> (tool: String, install: String)? {
        let pattern = "ERROR: ([A-Za-z0-9_.-]+) not found on PATH\\. Install it first: ([^\\r\\n\"\\\\]+)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) else { return nil }
        func group(_ i: Int) -> String {
            Range(m.range(at: i), in: output).map { String(output[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return (group(1), group(2))
    }

    public enum EmptyRun: Equatable {
        case missingTool(tool: String, install: String)
        case noTranscript
    }

    /// An organising run filed no item: why it failed, when its own output says. A missing tool comes first, before
    /// whatever else the agent said and before the next agent is tried: nothing comes of the run until the tool is
    /// installed, and it is the same for every agent. It is read whether or not a batch was written, and whether or not
    /// the live transcript was there: the recording's frames need ffmpeg too (frames.py), so a transcript that got past
    /// transcribe.py doesn't make the run a success. nil when the empty batch is an honest "nothing to file" (the words
    /// were there, or none were expected): that is still "done, 0 items".
    public static func emptyRun(hasBatch: Bool, output: String, captures: Bool, shots: Bool, videoOnly: Bool,
                                transcribed: Bool) -> EmptyRun? {
        if let tool = missingTool(in: output) { return .missingTool(tool: tool.tool, install: tool.install) }
        if hasBatch, emptyBatchFailed(captures: captures, shots: shots, videoOnly: videoOnly, transcribed: transcribed) { return .noTranscript }
        return nil
    }
}
