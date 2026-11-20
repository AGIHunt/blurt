import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Hotkeys (Carbon via BlurtCore.HotkeyCenter: work without Accessibility permission, even when we're not the
// active app). Configurable actions arrive through HotkeyCenter.onFire (and onRelease: voice input's push-to-talk);
// the fixed keys below (Esc for the pen and for voice input, ↩ / Esc / F / L in the picker) through onRaw.

enum HK: UInt32 {
    case pause = 1, stop = 3, toggleRec = 4, menu = 5, pen = 6, penEsc = 7, snap = 8, pickEnter = 10, pickEsc = 11,
         pickFull = 12, voice = 13, project = 14, voiceEsc = 15, cards = 16, cardsEsc = 17, dictationEsc = 18, reformat = 19, pickLast = 20, text = 21, translateText = 22,
         translateEsc = 23
}
var hotkeyHandler: ((HK) -> Void)?

func installHotkeyHandler() {
    let c = HotkeyCenter.shared
    c.installHandler()
    c.onRaw = { id in if let k = HK(rawValue: id) { hotkeyHandler?(k) } }
    c.onFire = { a in
        // a capability that is off does nothing, whoever asks: its keys aren't held, and a paired phone's buttons and
        // the test channel come through here too
        guard Capability.allows(a, off: Hotkeys.shared.resident ? Capability.off : [], recording: appDelegate?.rec != nil) else {
            emit(["event": "capability_off", "action": a.rawValue])
            // (a key of an off capability isn't held at all — the front app gets it): what reaches here is a paired
            // phone's button or a link, which said nothing — "Cards is off · Turn On"
            if let c = Capability.owner(of: a), !c.isOn {
                island.toast(T("feature.off_notice", T("feature.\(c.rawValue)")), key: "capability_off",
                             actionTitle: T("feature.turn_on")) {
                    Capability.set(c, on: true)
                    emit(["event": "capability_turned_on", "capability": c.rawValue, "via": "toast"])
                }
            }
            return
        }
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
