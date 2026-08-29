import Foundation
import Darwin

// These are C macros that Swift does not import.
private let kProcAllPIDs: UInt32 = 1                       // PROC_ALL_PIDS
private let kProcPathMax: Int32 = 4 * 1024                 // PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN)
private let kVMRegionBasicInfoCount64 = mach_msg_type_number_t(
    MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)

/// Locates the running game and its ASLR-slid module base.
public enum GameProcess {
    public static let bundleExecutable = "/Applications/Resident Evil 2.app/Contents/MacOS/Resident Evil 2"

    /// Version this trainer's offsets were derived from.
    public static let expectedVersion = "1.0.2"
    public static let expectedCDHash  = "adcde5dbe9400fc7f81e6a3762591504a871644f"

    public static func findPID() -> pid_t? {
        var count = proc_listpids(kProcAllPIDs, 0, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size)
        count = proc_listpids(kProcAllPIDs, 0, &pids, count)
        guard count > 0 else { return nil }
        var pathBuf = [CChar](repeating: 0, count: Int(kProcPathMax))
        for p in pids where p != 0 {
            if proc_pidpath(p, &pathBuf, UInt32(kProcPathMax)) > 0 {
                if String(cString: pathBuf) == bundleExecutable { return p }
            }
        }
        return nil
    }

    /// The lowest mapped address backed by the game binary == __TEXT start == module base.
    public static func moduleBase(_ mem: ProcessMemory) -> UInt64? {
        var address: mach_vm_address_t = 1
        var pathBuf = [CChar](repeating: 0, count: Int(kProcPathMax))
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_basic_info_data_64_t()
            var cnt = kVMRegionBasicInfoCount64
            var obj: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(cnt)) {
                    mach_vm_region(mem.task, &address, &size, VM_REGION_BASIC_INFO_64, $0, &cnt, &obj)
                }
            }
            guard kr == KERN_SUCCESS else { return nil }
            if proc_regionfilename(mem.pid, address, &pathBuf, UInt32(kProcPathMax)) > 0 {
                if String(cString: pathBuf) == bundleExecutable { return UInt64(address) }
            }
            address += size
        }
    }

    /// Refuse to apply offsets to a build they weren't derived from.
    public static func verifyBinary() -> (ok: Bool, detail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvvv", bundleExecutable]
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = Pipe()
        do { try p.run() } catch { return (false, "codesign failed to run") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }) else {
            return (false, "no CDHash in signature")
        }
        let hash = line.replacingOccurrences(of: "CDHash=", with: "").trimmingCharacters(in: .whitespaces)
        if hash == expectedCDHash { return (true, hash) }
        return (false, "CDHash \(hash) != expected \(expectedCDHash)")
    }
}
