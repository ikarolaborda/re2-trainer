import Foundation
import Darwin

/// Detects when the game is serializing a save, so the trainer can stop
/// writing to memory until it finishes.
///
/// Writing into the game's structures while `SaveThread_SerializeManager` is
/// walking them froze the game twice. The engine polls this before every write
/// pass and holds off while a save is running.
// C macro Swift does not import.
private let kThreadExtendedInfoCount = mach_msg_type_number_t(
    MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)

public enum SaveGuard {

    /// Thread-name fragments that indicate serialization in progress.
    public static let saveThreadMarkers = ["SaveThread", "SerializeManager"]

    /// True while any save-related thread of the target is actually running.
    public static func isSaving(_ mem: ProcessMemory) -> Bool {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mem.task, &threads, &count) == KERN_SUCCESS, let list = threads else {
            return false
        }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        }

        for i in 0..<Int(count) {
            var info = thread_extended_info_data_t()
            var icount = kThreadExtendedInfoCount
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(icount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &icount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }

            let name = withUnsafeBytes(of: &info.pth_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: Array(bytes) + [0])
            }
            guard !name.isEmpty else { continue }
            if saveThreadMarkers.contains(where: { name.contains($0) }),
               info.pth_run_state == TH_STATE_RUNNING {
                return true
            }
        }
        return false
    }
}
