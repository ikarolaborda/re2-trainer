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
    /// Fixed system path, deliberately not derived from a home directory.
    ///
    /// This used to resolve SUDO_USER and fall back to NSHomeDirectory(). That
    /// worked while both halves were started with `sudo`, but broke silently
    /// once the app began self-elevating through osascript: there SUDO_USER is
    /// unset, so the GUI wrote the lock to /var/root while the CLI kept looking
    /// in the user's home. The guard then never fired, and a GUI toggle could
    /// quietly revert CLI writes again -- exactly the bug the lock exists to
    /// prevent. Both halves run as root, so one absolute path always agrees.
    public static let lockURL = URL(fileURLWithPath: "/var/run/re2trainer-gui.lock")

    /// Locations used by earlier builds, cleaned up so a stale file there
    /// cannot be mistaken for a live owner.
    private static var legacyLocks: [URL] {
        var out = [URL(fileURLWithPath: "/var/root/.re2trainer-gui.lock")]
        if let u = ProcessInfo.processInfo.environment["SUDO_USER"], !u.isEmpty,
           let pw = getpwnam(u), let dir = pw.pointee.pw_dir {
            out.append(URL(fileURLWithPath: String(cString: dir))
                .appendingPathComponent(".re2trainer-gui.lock"))
        }
        out.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".re2trainer-gui.lock"))
        return out
    }

    public static func claim() {
        for u in legacyLocks { try? FileManager.default.removeItem(at: u) }
        try? String(getpid()).write(to: lockURL, atomically: true, encoding: .utf8)
    }

    public static func release() {
        try? FileManager.default.removeItem(at: lockURL)
        for u in legacyLocks { try? FileManager.default.removeItem(at: u) }
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
