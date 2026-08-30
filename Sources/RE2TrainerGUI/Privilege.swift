import Foundation
import AppKit

/// Re-launches the app as root when it was started by double-clicking.
///
/// Reading another process's memory needs `task_for_pid`, which needs root, so
/// the trainer has always been started with `sudo` from a terminal. Double
/// clicking gave a menu-bar item that could never attach. This relaunches the
/// same bundle through osascript's administrator prompt — the standard macOS
/// auth dialog — and hands off, so the app can be launched from the Dock like
/// any other.
enum Privilege {

    /// The command handed to osascript. Built separately so the quoting can be
    /// checked without triggering an authorisation prompt.
    static func appleScript(forExecutable exe: String) -> String {
        // Single-quote for the shell (POSIX-safe for spaces), then escape
        // backslashes and double quotes for the AppleScript string literal.
        let shell = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "' >/dev/null 2>&1 &"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func ensureRoot() {
        guard geteuid() != 0 else { return }        // already elevated

        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Escape for the AppleScript string literal, then for the shell.
        let shellQuoted = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        do shell script "\(shellQuoted.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")) \
        >/dev/null 2>&1 &" with administrator privileges
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSApplication.shared.terminate(nil)
            return
        }

        if p.terminationStatus != 0 {
            // User cancelled the password prompt, or authorisation failed.
            // Exiting is right: an unelevated instance can do nothing useful.
            exit(0)
        }
        exit(0)   // the elevated copy is now running; this one steps aside
    }
}
