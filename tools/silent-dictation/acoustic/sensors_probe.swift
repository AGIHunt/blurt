// Inventory probe: open each built-in SPU HID sensor and count input reports for 2 s (no root).
import Foundation
import IOKit
import IOKit.hid
let targets: [(Int, Int, String)] = [(0xFF00, 3, "accel?"), (0xFF00, 9, "gyro?"), (0xFF00, 4, "ALS?"), (0xFF00, 5, "?"),
                                     (0x20, 0x8A, "hinge/orientation?"), (0xFF0C, 1, "?"), (0xFF0C, 5, "?")]
final class Box { var n = 0; var last = [UInt8](); let name: String; init(_ s: String) { name = s } }
var boxes: [Box] = []
var it: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it)
var s = IOIteratorNext(it)
while s != 0 {
    let a = IORegistryEntrySetCFProperty(s, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
    let b = IORegistryEntrySetCFProperty(s, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
    let c = IORegistryEntrySetCFProperty(s, "ReportInterval" as CFString, 10000 as CFNumber)
    print("driver", s, String(format: "set: 0x%x 0x%x 0x%x", a, b, c))
    IOObjectRelease(s); s = IOIteratorNext(it)
}
for (page, usage, name) in targets {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: page, kIOHIDPrimaryUsageKey: usage, "Transport": "SPU"] as CFDictionary)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    let devs = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
    let label = String(format: "0x%X/%d %@", page, usage, name)
    print(label, "open:", r == kIOReturnSuccess ? "ok" : String(format: "0x%x", r), "devices:", devs.count)
    for d in devs {
        let b = Box(label); boxes.append(b)
        IOHIDDeviceSetProperty(d, "ReportInterval" as CFString, 10000 as CFNumber)
        let size = (IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
        IOHIDDeviceRegisterInputReportCallback(d, buf, max(size, 1), { ctx, _, _, _, _, rep, len in
            let b = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue(); b.n += 1; b.last = Array(UnsafeBufferPointer(start: rep, count: len))
        }, Unmanaged.passUnretained(b).toOpaque())
    }
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}
RunLoop.current.run(until: Date().addingTimeInterval(2))
for b in boxes { print(b.name, "reports in 2 s:", b.n, "last:", b.last.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")) }
