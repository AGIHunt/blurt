import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Hotkeys (Carbon via BlurtCore.HotkeyCenter: work without Accessibility permission, even when we're not the
// active app). Configurable actions arrive through HotkeyCenter.onFire (and onRelease: voice input's push-to-talk);
// the fixed keys below (Esc for the pen and for voice input, ↩ / Esc / F in the picker) through onRaw.

enum HK: UInt32 {
    case pause = 1, marker = 2, stop = 3, toggleRec = 4, menu = 5, pen = 6, penEsc = 7, snap = 8, pickEnter = 10, pickEsc = 11,
         pickFull = 12, voice = 13, project = 14, voiceEsc = 15, dictationEsc = 16
}
var hotkeyHandler: ((HK) -> Void)?

func installHotkeyHandler() {
    let c = HotkeyCenter.shared
    c.installHandler()
    c.onRaw = { id in if let k = HK(rawValue: id) { hotkeyHandler?(k) } }
    c.onFire = { a in
        if let k = a.hk { hotkeyHandler?(k) } else if a == .openMain { AppEnvironment.mainWindow?.show() }
    }
    c.onRelease = { a in if a == .voice { VoiceInput.shared.released() } }
}

@discardableResult
func registerHotkey(_ k: HK, key: Int, mods: Int) -> OSStatus { HotkeyCenter.shared.registerRaw(k.rawValue, code: key, mods: mods) }

func unregisterHotkey(_ k: HK) { HotkeyCenter.shared.unregisterRaw(k.rawValue) }

var signalSources: [DispatchSourceSignal] = []

/// Called by the recorder when a take ends (stopped / cancelled / error). CLI mode exits; the menu-bar app carries on.
var sessionEnded: (Int32, [String: Any]) -> Void = { code, event in
    emit(event)
    DispatchQueue.main.asyncAfter(deadline: .now() + (code == 0 ? 0.4 : 0)) { exit(code) }
}
