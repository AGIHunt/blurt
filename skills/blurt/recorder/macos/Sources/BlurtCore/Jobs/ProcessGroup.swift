// A child process that leads its own process group (posix_spawn POSIX_SPAWN_SETPGROUP), so everything it starts —
// an organising agent's zsh, the agent, its tools — can be stopped together with killpg. Foundation's Process can't
// do this: a child's own children otherwise outlive the app, unseen, still spending tokens (dogfood v0.9).
//
//   let p = try ProcessGroup.spawn("/bin/zsh", ["-c", cmd], env: env, cwd: dir, output: fh) { status in … }
//   p.pgid, p.started           → record both in the job ("agent_pgid", "agent_pgid_start") so a later launch can
//                                 find it — and tell it from an unrelated group that got the same number since
//   ProcessGroup.stop(pgid)     → SIGTERM the group, SIGKILL whatever is left after a grace period
//   ProcessGroup.isOurs(pgid, started:) → before stopping a group a previous run recorded: its leader is still the
//                                 process that was started (same start time), or, the leader gone, what is left all
//                                 started after it. A number reused by the user's shell or editor after a reboot is
//                                 never ours.
import Darwin
import Foundation

public final class ProcessGroup {
    public let pgid: pid_t
    /// The leader's start time (µs since 1970, from the kernel), nil if it couldn't be read.
    public let started: UInt64?

    private init(pgid: pid_t) { self.pgid = pgid; started = Self.startTime(pgid) }

    public enum SpawnError: Error, CustomStringConvertible {
        case failed(Int32, String)
        public var description: String {
            if case .failed(let e, let exe) = self { return "\(exe): \(String(cString: strerror(e)))" }
            return "spawn failed"
        }
    }

    /// Start `exe` with `args` in a new process group (its pid is the group id), stdin from /dev/null, stdout and
    /// stderr to `output` (nil = /dev/null). `onExit` runs on the main queue with the exit status (128 + signal when
    /// it was killed).
    public static func spawn(_ exe: String, _ args: [String], env: [String: String], cwd: URL, output: FileHandle?,
                             onExit: @escaping (Int32) -> Void) throws -> ProcessGroup {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        // the app ignores SIGTERM / SIGINT (it handles them on a dispatch source): the child must not inherit that
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        if let fd = output?.fileDescriptor {
            posix_spawn_file_actions_adddup2(&fa, fd, 1)
            posix_spawn_file_actions_adddup2(&fa, fd, 2)
        } else {
            posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir_np(&fa, cwd.path)
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
        guard rc == 0 else { throw SpawnError.failed(rc, exe) }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { onExit(code) }
        }
        return ProcessGroup(pgid: pid)
    }

    /// A process's start time in µs since 1970 (proc_pidinfo PROC_PIDTBSDINFO), nil when it doesn't exist.
    public static func startTime(_ pid: pid_t) -> UInt64? {
        bsdInfo(pid).map { UInt64($0.pbi_start_tvsec) * 1_000_000 + UInt64($0.pbi_start_tvusec) }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// The pids in process group `pgid` (sysctl KERN_PROC_PGRP).
    public static func members(_ pgid: pid_t) -> [pid_t] {
        guard pgid > 1 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 4)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    /// Is `pgid` still the group this app started at `started` (its leader's start time)? With its leader alive:
    /// the same start time. With the leader gone: what is left of the group (the agent and its tools) all started
    /// after it — a group id is only ever reused by a new leader of that pid, which would be there. Without a
    /// recorded start time (a job from an older build) nothing can be told, so nothing is ours. (A process's
    /// environment — BLURT_JOB — can't be read: macOS withholds it from KERN_PROCARGS2.)
    public static func isOurs(_ pgid: pid_t, started: UInt64?) -> Bool {
        guard pgid > 1, pgid != getpgrp(), let s = started else { return false }
        if let leader = bsdInfo(pgid) {
            return UInt64(leader.pbi_start_tvsec) * 1_000_000 + UInt64(leader.pbi_start_tvusec) == s && leader.pbi_pgid == UInt32(pgid)
        }
        let left = members(pgid)
        return !left.isEmpty && left.allSatisfy { (startTime($0) ?? 0) >= s }
    }

    /// Is anything of the group still running?
    public static func alive(_ pgid: pid_t) -> Bool {
        guard pgid > 1 else { return false }
        return killpg(pgid, 0) == 0 || errno == EPERM
    }

    /// SIGTERM the whole group; after `grace` seconds, SIGKILL whatever is left. Blocks for at most `grace`.
    public static func stop(_ pgid: pid_t, grace: TimeInterval = 1.5) {
        guard pgid > 1, alive(pgid) else { return }
        killpg(pgid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while alive(pgid), Date() < deadline { usleep(50_000) }
        if alive(pgid) { killpg(pgid, SIGKILL) }
    }
}
