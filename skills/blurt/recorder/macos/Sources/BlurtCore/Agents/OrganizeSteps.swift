// Which step of an organising run (process job: prepare → transcribe → write → frames) a failure belongs to. The whole
// agent runs under "transcribe" (it transcribes, writes and picks frames itself), so a failure used to be blamed on
// transcription even when the agent couldn't sign in, ran out of quota or had no network. Now:
//   a transcript was written         → transcription is done; writing the items failed
//   auth / quota / network / model   → the agent itself couldn't work: preparing it failed, transcription never ran
//   anything else                    → the step it was in (transcribe) failed, as before
import Foundation

public enum OrganizeSteps {
    /// Failure classes that are about the agent, not the recording (agents.json failures).
    public static let agentLevel: Set<String> = ["auth", "quota", "network", "model"]

    /// The step states to set before the job finishes as failed (finish closes what is still running as failed and
    /// what is still pending as skipped).
    public static func onFailure(failureClass: String?, transcribed: Bool) -> [(step: String, state: StepState)] {
        if transcribed { return [("transcribe", .done), ("write", .failed)] }
        if let c = failureClass, agentLevel.contains(c) { return [("transcribe", .pending), ("prepare", .failed)] }
        return [("transcribe", .failed)]
    }
}
