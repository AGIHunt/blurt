// NoteVoice's converter keeps fewer channels than the device has (an audio interface's two ins and its loopback pair,
// MiniFuse 1: four). AVAudioConverter's own map for that drop is all -1 — silence, with no error to say so. This is
// what to give it instead. Unit-tested in Tests/BlurtCoreTests/MicChannelMapTests.
public enum MicChannelMap {
    /// The map to give a converter whose own map carries nothing: the device's first channels. nil when the map as it
    /// stands is fine (it carries sound, or its length is not what it claims).
    public static func silenceFix(device: Int, kept: Int, map: [Int]) -> [Int]? {
        guard device > kept, kept > 0, map.count == kept, map.allSatisfy({ $0 < 0 }) else { return nil }
        return Array(0..<kept)
    }
}
