// Lists what CoreAudio really exposes for every audio device. No sound is played or recorded.
import AVFoundation
import CoreAudio

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = addr(s, scope), v: UInt32 = 0, n = UInt32(4)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) == 0 ? v : nil
}
func f64(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Double? {
    var a = addr(s, scope), v: Double = 0, n = UInt32(8)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) == 0 ? v : nil
}
func str(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s), v: Unmanaged<CFString>? = nil, n = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) == 0, let r = v else { return "?" }
    return r.takeRetainedValue() as String
}
func ranges(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioValueRange] {
    var a = addr(s, scope), n = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == 0, n > 0 else { return [] }
    var out = [AudioValueRange](repeating: .init(), count: Int(n)/MemoryLayout<AudioValueRange>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &out) == 0 ? out : []
}
func objects(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = addr(s, scope), n = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == 0, n > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(n)/4)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &n, &out) == 0 ? out : []
}
func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [UInt32] {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope), n = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == 0, n > 0 else { return [] }
    let p = UnsafeMutableRawPointer.allocate(byteCount: Int(n), alignment: 16); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, p) == 0 else { return [] }
    return UnsafeMutableAudioBufferListPointer(p.assumingMemoryBound(to: AudioBufferList.self)).map { $0.mNumberChannels }
}
func present(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ el: UInt32) -> (settable: Bool, value: Float32)? {
    var a = AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: el)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var v: Float32 = 0, n = UInt32(4), w: DarwinBoolean = false
    AudioObjectIsPropertySettable(id, &a, &w)
    if AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) != 0 { return nil }
    return (w.boolValue, v)
}

print("mic auth (AVCaptureDevice):", AVCaptureDevice.authorizationStatus(for: .audio).rawValue, " 3=authorized 2=denied 0=notDetermined")
for d in objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
    print("\n#\(d) \(str(d, kAudioObjectPropertyName)) uid=\(str(d, kAudioDevicePropertyDeviceUID)) transport=\(u32(d, kAudioDevicePropertyTransportType).map { String(format: "%08x", $0) } ?? "?") hidden=\(u32(d, kAudioDevicePropertyIsHidden) ?? 99) clockDomain=\(u32(d, kAudioDevicePropertyClockDomain) ?? 0)")
    print("  rate now=\(f64(d, kAudioDevicePropertyNominalSampleRate) ?? 0) available=\(ranges(d, kAudioDevicePropertyAvailableNominalSampleRates).map { $0.mMinimum == $0.mMaximum ? "\(Int($0.mMinimum))" : "\(Int($0.mMinimum))-\(Int($0.mMaximum))" })")
    print("  bufferFrames now=\(u32(d, kAudioDevicePropertyBufferFrameSize) ?? 0) range=\(ranges(d, kAudioDevicePropertyBufferFrameSizeRange).map { "\(Int($0.mMinimum))-\(Int($0.mMaximum))" })")
    for (name, scope) in [("in", kAudioObjectPropertyScopeInput), ("out", kAudioObjectPropertyScopeOutput)] {
        let ch = channels(d, scope); if ch.isEmpty { continue }
        print("  \(name): streams=\(ch) latency=\(u32(d, kAudioDevicePropertyLatency, scope) ?? 0) safety=\(u32(d, kAudioDevicePropertySafetyOffset, scope) ?? 0)")
        for s in objects(d, kAudioDevicePropertyStreams, scope) {
            var a = addr(kAudioStreamPropertyAvailablePhysicalFormats), n = UInt32(0)
            if AudioObjectGetPropertyDataSize(s, &a, 0, nil, &n) == 0, n > 0 {
                var f = [AudioStreamRangedDescription](repeating: .init(), count: Int(n)/MemoryLayout<AudioStreamRangedDescription>.size)
                AudioObjectGetPropertyData(s, &a, 0, nil, &n, &f)
                print("    stream \(s) phys formats:", Set(f.map { "\(Int($0.mFormat.mSampleRate))Hz/\($0.mFormat.mChannelsPerFrame)ch/\($0.mFormat.mBitsPerChannel)b" }).sorted())
            }
        }
        for (label, sel) in [("volume", kAudioDevicePropertyVolumeScalar), ("mute", kAudioDevicePropertyMute), ("playthru", kAudioDevicePropertyPlayThru)] {
            for el in [UInt32(0), 1, 2, 3] {
                if let p = present(d, sel, scope, el) { print("    \(label)[\(el)]=\(p.value) settable=\(p.settable)") }
            }
        }
        var ds = addr(kAudioDevicePropertyDataSources, scope), n = UInt32(0)
        if AudioObjectGetPropertyDataSize(d, &ds, 0, nil, &n) == 0, n > 0 {
            var v = [UInt32](repeating: 0, count: Int(n)/4)
            AudioObjectGetPropertyData(d, &ds, 0, nil, &n, &v)
            print("    dataSources:", v.map { String(format: "%08x", $0) })
        }
    }
}
// Hidden built-in devices are not in the list above but can be reached by UID.
for uid in ["BuiltInMicrophoneDevice", "BuiltInSpeakerDevice", "BuiltInSpeakerDevice2", "AppleUSBAudioEngine", "BuiltInHeadphoneOutputDevice", "BuiltInMicrophoneDevice2", "MicrophoneArray", "BuiltInMicArrayDevice", "BuiltInRawMicrophoneDevice"] {
    var a = addr(kAudioHardwarePropertyTranslateUIDToDevice), cf = uid as CFString, id = AudioObjectID(0), n = UInt32(4)
    let st = withUnsafePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &n, &id) }
    print("UID \(uid): st=\(st) id=\(id) \(id != 0 ? str(id, kAudioObjectPropertyName) : "")")
}
