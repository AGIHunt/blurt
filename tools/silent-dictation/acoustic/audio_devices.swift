// List every CoreAudio device (incl. hidden), streams, channel counts, physical formats.
import CoreAudio
import Foundation
func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ v: T) -> T? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var x = v; var sz = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &x) == noErr ? x : nil
}
func arr(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(sz) / 4); AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &out); return out
}
func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == noErr ? (s?.takeRetainedValue() as String? ?? "") : "?"
}
// plug-ins, boxes, devices (the device list hides hidden devices; boxes and plug-ins may reveal more)
print("plug-ins:"); for p in arr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyPlugInList) { print("  ", str(p, kAudioPlugInPropertyBundleID)) }
print("boxes:"); for b in arr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyBoxList) { print("  ", str(b, kAudioObjectPropertyName), str(b, kAudioBoxPropertyBoxUID)) }
var all = Set(arr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices))
for p in arr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyPlugInList) { all.formUnion(arr(p, kAudioPlugInPropertyDeviceList)) }
for d in all.sorted() {
    let hidden = get(d, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
    print("device \(d) \(str(d, kAudioObjectPropertyName)) uid=\(str(d, kAudioDevicePropertyDeviceUID)) hidden=\(hidden)")
    for (scope, n) in [(kAudioObjectPropertyScopeInput, "in"), (kAudioObjectPropertyScopeOutput, "out")] {
        for s in arr(d, kAudioDevicePropertyStreams, scope) {
            var a = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0; AudioObjectGetPropertyDataSize(s, &a, 0, nil, &sz)
            var fm = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(sz) / MemoryLayout<AudioStreamRangedDescription>.size)
            AudioObjectGetPropertyData(s, &a, 0, nil, &sz, &fm)
            let desc = Set(fm.map { "\($0.mFormat.mChannelsPerFrame)ch@\(Int($0.mFormat.mSampleRate))/\($0.mFormat.mBitsPerChannel)b" }).sorted().joined(separator: " ")
            print("   \(n) stream \(s): \(desc)")
        }
    }
}
