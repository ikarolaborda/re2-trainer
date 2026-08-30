import Foundation

/// Marks the GUI as the owner of trainer state.
///
/// The CLI and the GUI write the same engine flags. Without coordination a CLI
/// command appears to work and is then silently reverted by a GUI toggle a
/// second later — which happened twice: clearing NoDamage while its switch was
/// still on, and restarting the game clock while Freeze Timer was on.
///
/// The GUI writes this lock while attached and asserts its toggle states every
/// pass, so it is authoritative. The CLI checks the lock and refuses to make
/// conflicting changes unless forced.
public enum Ownership {
    /// The real user's home, not root's.
    ///
    /// Both halves of the trainer need task_for_pid and so run under sudo,
    /// where NSHomeDirectory() is /var/root. Resolving SUDO_USER keeps the CLI
    /// and the GUI pointed at the same file regardless of how each was started.
    static var homeDir: String {
        if let u = ProcessInfo.processInfo.environment["SUDO_USER"], !u.isEmpty,
           let pw = getpwnam(u), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public static var lockURL: URL {
        URL(fileURLWithPath: homeDir).appendingPathComponent(".re2trainer-gui.lock")
    }

    public static func claim() {
        try? String(getpid()).write(to: lockURL, atomically: true, encoding: .utf8)
    }

    public static func release() {
        try? FileManager.default.removeItem(at: lockURL)
    }

    /// PID of a live GUI holding the lock, if any. Stale locks are cleaned up.
    public static func heldBy() -> pid_t? {
        guard let s = try? String(contentsOf: lockURL, encoding: .utf8),
              let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        if kill(p, 0) != 0 { release(); return nil }   // stale
        return p
    }
}
