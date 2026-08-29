import Foundation
import Darwin

/// Thin wrapper over the Mach VM APIs for reading/writing another process.
///
/// Requires root: the target (Resident Evil 2, Mac App Store build) is signed
/// *without* the hardened runtime, so `task_for_pid` succeeds for root even
/// with SIP enabled. A hardened-runtime target would refuse.
struct ProcessMemory {
    let pid: pid_t
    let task: mach_port_t

    init?(pid: pid_t) {
        var t: mach_port_t = 0
        guard task_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return nil }
        self.pid = pid
        self.task = t
    }

    func read(_ address: UInt64, count: Int) -> Data? {
        var out = Data(count: count)
        var got: mach_vm_size_t = 0
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return mach_vm_read_overwrite(task, address, mach_vm_size_t(count),
                                          mach_vm_address_t(UInt(bitPattern: base)), &got) == KERN_SUCCESS
        }
        return (ok && Int(got) == count) ? out : nil
    }

    func readU64(_ address: UInt64) -> UInt64? {
        guard let d = read(address, count: 8) else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    func readI32(_ address: UInt64) -> Int32? {
        guard let d = read(address, count: 4) else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    }

    @discardableResult
    func writeI32(_ address: UInt64, _ value: Int32) -> Bool {
        var v = value
        return withUnsafeBytes(of: &v) { buf in
            mach_vm_write(task, address,
                          vm_offset_t(UInt(bitPattern: buf.baseAddress)),
                          mach_msg_type_number_t(4)) == KERN_SUCCESS
        }
    }
}
