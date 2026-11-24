// What this Mac's keyboard layout prints on its keys, for a phone's computer keyboard (docs/design/remote.md §Computer keyboard). With a
// Chinese or Japanese input method in use it's the layout under it; the input source's own name goes along, so the phone can say which is on.
import AppKit
import BlurtRemoteKit
import Carbon.HIToolbox

enum RemoteLayout {
    /// The input source changed (the menu bar, a shortcut, another app's).
    static let changed = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// Main thread only, as Text Input Sources asks.
    static func legends() -> RemoteLegends? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        var keys: [String: RemoteLegends.Key] = [:]
        data.withUnsafeBytes { p in
            guard let l = p.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            func type(_ code: UInt16, shift: Bool) -> String? {
                var dead: UInt32 = 0, n = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let ok = UCKeyTranslate(l, code, UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &n, &chars)
                guard ok == noErr, n > 0 else { return nil }
                let s = String(utf16CodeUnits: chars, count: n)
                return s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) ? s : nil
            }
            for name in RemoteLegends.names {
                guard let k = RemoteKey.named(name), let base = type(k.code, shift: false) else { continue }
                keys[name] = .init(base: base, shift: type(k.code, shift: true) ?? base)
            }
        }
        return RemoteLegends(source: name, keys: keys)
    }
}
