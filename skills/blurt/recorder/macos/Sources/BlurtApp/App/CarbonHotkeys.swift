import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Hotkeys (Carbon: work without Accessibility permission, even when we're not the active app)

enum HK: UInt32 { case pause = 1, marker = 2, stop = 3, toggleRec = 4, menu = 5, pen = 6, penEsc = 7, snap = 8, pickEnter = 10, pickEsc = 11, pickFull = 12 }
var hotkeyHandler: ((HK) -> Void)?
var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]

func installHotkeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        if let k = HK(rawValue: id.id) { hotkeyHandler?(k) }
        return noErr
    }, 1, &spec, nil, nil)
}

@discardableResult
func registerHotkey(_ k: HK, key: Int, mods: Int) -> OSStatus {
    guard hotkeyRefs[k.rawValue] == nil else { return noErr }
    var ref: EventHotKeyRef?
    let st = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x626C7274), id: k.rawValue),
                                 GetApplicationEventTarget(), 0, &ref)
    if let r = ref { hotkeyRefs[k.rawValue] = r }
    return st
}

func unregisterHotkey(_ k: HK) {
    if let r = hotkeyRefs.removeValue(forKey: k.rawValue) { UnregisterEventHotKey(r) }
}

var signalSources: [DispatchSourceSignal] = []

/// Called by the recorder when a take ends (stopped / cancelled / error). CLI mode exits; the menu-bar app carries on.
var sessionEnded: (Int32, [String: Any]) -> Void = { code, event in
    emit(event)
    DispatchQueue.main.asyncAfter(deadline: .now() + (code == 0 ? 0.4 : 0)) { exit(code) }
}
