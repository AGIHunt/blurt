// Plays a stereo stimulus through the built-in speakers while recording the built-in mic, sample-locked:
// both run in one callback of a private aggregate device, so the output-to-input delay is fixed for a run.
// Usage: duplex --rate 96000 --stim in.f32 --out out.f32 [--tail-seconds 0.3] [--volume 0.19]
// stim is interleaved stereo Float32; out is mono Float32. Restores sample rates and volume on exit.
import CoreAudio
import Foundation

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--\(name)"), i+1 < a.count else { return nil }
    return a[i+1]
}
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func device(_ uid: String) -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyTranslateUIDToDevice), cf = uid as CFString, id = AudioObjectID(0), n = UInt32(4)
    _ = withUnsafePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &n, &id) }
    return id
}
func rate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate), v = 0.0, n = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v); return v
}
func setRate(_ id: AudioObjectID, _ r: Double) {
    var a = addr(kAudioDevicePropertyNominalSampleRate), v = r
    AudioObjectSetPropertyData(id, &a, 0, nil, 8, &v)
    for _ in 0..<100 where rate(id) != r { usleep(20_000) }
}
func volume(_ id: AudioObjectID) -> Float32 {
    var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), v: Float32 = 0, n = UInt32(4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v); return v
}
func setVolume(_ id: AudioObjectID, _ x: Float32) {
    var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), v = x
    AudioObjectSetPropertyData(id, &a, 0, nil, 4, &v)
}

let target = Double(arg("rate") ?? "96000")!
let stimData = try! Data(contentsOf: URL(fileURLWithPath: arg("stim")!))
let stim: [Float] = stimData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
guard let peak = stim.map({ abs($0) }).max(), peak <= 0.5 else { fatalError("stimulus peak above 0.5 refused") }
let tail = Int(Double(arg("tail-seconds") ?? "0.3")! * target)
let stimFrames = stim.count/2, totalFrames = stimFrames + tail

let mic = device("BuiltInMicrophoneDevice"), spk = device("BuiltInSpeakerDevice")
let oldMic = rate(mic), oldSpk = rate(spk), oldVol = volume(spk)
if let v = arg("volume") { setVolume(spk, Float32(v)!) }
setRate(mic, target); setRate(spk, target)

let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Blurt Sonar", kAudioAggregateDeviceUIDKey: "local.blurt.sonar.\(getpid())",
    kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceMainSubDeviceKey: "BuiltInSpeakerDevice",
    kAudioAggregateDeviceClockDeviceKey: "BuiltInSpeakerDevice",
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: "BuiltInMicrophoneDevice"], [kAudioSubDeviceUIDKey: "BuiltInSpeakerDevice"]],
]
var agg = AudioObjectID(0)
var st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
guard st == 0 else { fatalError("aggregate failed \(st)") }
usleep(200_000)
setRate(agg, target)

final class Run: @unchecked Sendable {
    var played = 0, inCount = 0, sync = 0
    var rec: UnsafeMutablePointer<Float>
    let frames: Int
    let done = DispatchSemaphore(value: 0)
    var signaled = false
    init(_ f: Int) { frames = f; rec = .allocate(capacity: f); rec.initialize(repeating: 0, count: f) }
}
let run = Run(totalFrames)
var procID: AudioDeviceIOProcID?
st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inData, _, outData, _ in
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    if let b = ins.first, let p = b.mData {
        let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize)/4/ch, f = p.assumingMemoryBound(to: Float.self)
        for i in 0..<n where run.inCount < run.frames { run.rec[run.inCount] = f[i*ch]; run.inCount += 1 }
    }
    if let b = outs.first, let p = b.mData {
        let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize)/4/ch, f = p.assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            let k = run.played; run.played += 1
            for c in 0..<ch { f[i*ch+c] = (c < 2 && k < stimFrames) ? stim[k*2+c] : 0 }
        }
    }
    if run.inCount >= run.frames && !run.signaled { run.signaled = true; run.done.signal() }
}
guard st == 0 else { fatalError("ioproc \(st)") }
st = AudioDeviceStart(agg, procID)
guard st == 0 else { fatalError("start \(st)") }
let timeout = Double(totalFrames)/target + 3
let result = run.done.wait(timeout: .now() + timeout)
AudioDeviceStop(agg, procID); AudioDeviceDestroyIOProcID(agg, procID!)
AudioHardwareDestroyAggregateDevice(agg)
setRate(mic, oldMic); setRate(spk, oldSpk); setVolume(spk, oldVol)
guard result == .success else { fatalError("timed out, captured \(run.inCount)/\(totalFrames) rate=\(rate(agg))") }
let out = Data(bytes: run.rec, count: totalFrames*4)
try! out.write(to: URL(fileURLWithPath: arg("out")!))
print("ok frames=\(totalFrames) rate=\(target) oldVol=\(oldVol)")
