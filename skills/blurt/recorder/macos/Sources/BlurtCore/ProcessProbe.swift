// Read-only facts about a process of this user, for telling a warm model server that is working from one that is
// stuck (WarmServer.diagnose): its command line (KERN_PROCARGS2), when it started and how much CPU time it has used
// (proc_pidinfo). Nothing here signals or changes a process.
import Darwin
import Foundation

public enum ProcessProbe {
    /// The process exists (a process of another user counts too: kill(0) says EPERM).
    public static func alive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// When it started; nil when it doesn't exist.
    public static func started(_ pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// User + system CPU time so far (s); nil when it can't be read.
    public static func cpuSeconds(_ pid: pid_t) -> Double? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // mach time units (nanoseconds on Intel, ticks on Apple silicon)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = Double(info.pti_total_user) + Double(info.pti_total_system)
        return ticks * Double(tb.numer) / Double(max(1, tb.denom)) / 1_000_000_000
    }

    /// Its parent's pid; nil when it can't be read.
    public static func parent(_ pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The process and its ancestors, nearest first, each as its argv (one that can't be read is left out), up to
    /// `max` of them, launchd never.
    public static func ancestry(_ pid: pid_t, max: Int = 16) -> [[String]] {
        var out: [[String]] = []
        var p = pid
        var seen = Set<pid_t>()
        while p > 1, out.count < max, seen.insert(p).inserted {
            if let a = arguments(p), !a.isEmpty { out.append(a) }
            guard let up = parent(p) else { break }
            p = up
        }
        return out
    }

    /// Its argv (KERN_PROCARGS2); nil when it can't be read.
    public static func arguments(_ pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }          // the executable's path
        while i < size, buf[i] == 0 { i += 1 }          // its padding
        var args: [String] = []
        while i < size, args.count < Int(argc) {
            let s = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
