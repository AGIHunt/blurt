// 保持可连接 / Stay awake for remote access (docs/design/remote-1.1.md §1): while devices can connect to this Mac it doesn't idle-sleep,
// so it's there when someone reaches for it from the office. Only the computer stays awake; the display still turns off on its own timer,
// so nothing stays lit. A laptop does this only while plugged in (on battery it sleeps as usual), and a closed lid sleeps it whatever this
// says: macOS decides that. On by default; Settings → Remote Control turns it off.
import Foundation
import BlurtCore
import IOKit.ps
import IOKit.pwr_mgt

final class RemoteStayAwake {
    static let shared = RemoteStayAwake()

    static var enabled: Bool { Config.shared["record.remote.stay_awake"] as? Bool ?? true }

    /// A Mac with a battery: it stays awake only while plugged in.
    static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { s in
            (IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    private static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        return (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
    }

    private var listening = false
    private var assertion: IOPMAssertionID = 0
    private var watching: CFRunLoopSource?

    /// Devices can connect (RemoteServer is listening), or no longer.
    func listening(_ on: Bool) {
        DispatchQueue.main.async {
            self.listening = on
            self.watchPower()
            self.refresh()
        }
    }

    /// The setting changed.
    func settingChanged() { DispatchQueue.main.async { self.refresh() } }

    private func refresh() {
        let want = listening && Self.enabled && (!Self.hasBattery || Self.onPower)
        let held = assertion != 0
        guard want != held else { return }
        if want {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Blurt: stay awake for remote access" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        emit(["event": "remote_stay_awake", "on": assertion != 0, "battery": Self.hasBattery])
    }

    /// Plugged in or out: a laptop's answer changes with it.
    private func watchPower() {
        guard watching == nil, Self.hasBattery else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<RemoteStayAwake>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, me)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        watching = s
    }
}
