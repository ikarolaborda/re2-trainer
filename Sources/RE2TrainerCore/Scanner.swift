import Foundation
import Darwin

// Macros Swift does not import.
private let kVMRegionBasicInfoCount64 = mach_msg_type_number_t(
    MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)

public extension ProcessMemory {
    /// Walks every readable+writable region, handing each chunk to `body`.
    /// Everything signature-based is built on this.
    func scanWritableRegions(chunk: Int = 4 << 20,
                             minAddress: UInt64 = 0x400000000,
                             _ body: (UInt64, UnsafeRawBufferPointer) -> Void) {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 8)
        defer { buf.deallocate() }
        var address: mach_vm_address_t = 1
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_basic_info_data_64_t()
            var cnt = kVMRegionBasicInfoCount64
            var obj: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(cnt)) {
                    mach_vm_region(task, &address, &size, VM_REGION_BASIC_INFO_64, $0, &cnt, &obj)
                }
            }
            guard kr == KERN_SUCCESS else { break }
            let readable = (info.protection & VM_PROT_READ) != 0
            let writable = (info.protection & VM_PROT_WRITE) != 0
            if readable && writable {
                var off: mach_vm_size_t = 0
                while off < size {
                    let len = min(mach_vm_size_t(chunk), size - off)
                    let base = UInt64(address) + UInt64(off)
                    var got: mach_vm_size_t = 0
                    if base >= minAddress,
                       mach_vm_read_overwrite(task, base, len,
                                              mach_vm_address_t(UInt(bitPattern: buf)), &got) == KERN_SUCCESS,
                       got == len {
                        body(base, UnsafeRawBufferPointer(start: buf, count: Int(len)))
                    }
                    off += len
                }
            }
            address += size
        }
    }
}

/// A health component: +0x00 marker(1), +0x04 max, +0x08 current.
public struct HealthComponent {
    public let address: UInt64
    public let maxHP: Int32
    public var currentOffset: UInt64 { address &+ 8 }
}

public enum Scanner {
    public static let playerMaxHP: Int32 = 1200

    /// Enemy max-HP values confirmed by observation. Zombie = 620, verified by
    /// diffing memory across a kill.
    ///
    /// Deliberately an allow-list. A generic "any health-shaped struct that
    /// isn't the player" signature matches ~86,000 locations in a live game --
    /// almost all of them ordinary data -- and writing to those would be
    /// reckless. Add types here only once their max HP is confirmed the same
    /// way: snapshot, damage one, diff.
    public static let knownEnemyMaxHP: Set<Int32> = [620]

    /// Finds enemy health components by struct shape, restricted to confirmed
    /// enemy types. No addresses or offsets, so this survives ASLR, restarts,
    /// other machines, and game patches.
    public static func enemyHealth(_ mem: ProcessMemory,
                                   allowed: Set<Int32>? = nil) -> [HealthComponent] {
        let types = allowed ?? knownEnemyMaxHP
        var out: [HealthComponent] = []
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 12 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: Int32.self) == 1 {
                    let m = buf.loadUnaligned(fromByteOffset: i + 4, as: Int32.self)
                    if types.contains(m), m != playerMaxHP {
                        let c = buf.loadUnaligned(fromByteOffset: i + 8, as: Int32.self)
                        if c >= 0, c <= m {
                            out.append(HealthComponent(address: base &+ UInt64(i), maxHP: m))
                        }
                    }
                }
                i += 4
            }
        }
        return out
    }

    /// The inventory item vtable moves every launch, but its low bits have been
    /// stable (0xa26058) across every session observed. Derive it at runtime
    /// rather than baking in an address.
    public static let itemVTableLowBits: UInt64 = 0xa26058

    public static func itemVTable(_ mem: ProcessMemory) -> UInt64? {
        var counts: [UInt64: Int] = [:]
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 0x30 <= buf.count {
                let p = buf.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                if p & 0xFFFFFF == itemVTableLowBits, p > 0x400000000, p < 0x2000000000 {
                    let wep = buf.loadUnaligned(fromByteOffset: i + 0x14, as: Int32.self)
                    if wep >= -1 && wep < 300 { counts[p, default: 0] += 1 }
                }
                i += 8
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    /// Item entry: +0x10 itemID, +0x14 weaponID, +0x18 upgrades,
    ///             +0x1c ammoType, +0x20 quantity
    public static func weaponEntries(_ mem: ProcessMemory, vtable: UInt64, weaponID: Int32) -> [UInt64] {
        var out: [UInt64] = []
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 0x30 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: UInt64.self) == vtable {
                    let item = buf.loadUnaligned(fromByteOffset: i + 0x10, as: Int32.self)
                    let wep = buf.loadUnaligned(fromByteOffset: i + 0x14, as: Int32.self)
                    if item == 0 && wep == weaponID { out.append(base &+ UInt64(i)) }
                }
                i += 8
            }
        }
        return out
    }
    public static let quantityOffset: UInt64 = 0x20

    /// Player health components, found by signature rather than pointer chains.
    ///
    /// Pointer chains proved unreliable for this game: a set of 61 chains that
    /// all resolved correctly through one restart resolved through *none* of the
    /// next one. The player's max HP (1200) is distinctive and no enemy shares
    /// it, so the struct shape is a far more durable anchor than any offset --
    /// and it needs no module base, so it is immune to ASLR and to game patches.
    public static func playerHealth(_ mem: ProcessMemory) -> [HealthComponent] {
        var out: [HealthComponent] = []
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 12 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: Int32.self) == 1 {
                    let m = buf.loadUnaligned(fromByteOffset: i + 4, as: Int32.self)
                    let c = buf.loadUnaligned(fromByteOffset: i + 8, as: Int32.self)
                    if m == playerMaxHP, c >= 0, c <= m {
                        out.append(HealthComponent(address: base &+ UInt64(i), maxHP: m))
                    }
                }
                i += 4
            }
        }
        return out
    }
}

// MARK: - Scan-and-apply
//
// These write *during* the scan, so a target is only ever written at the moment
// it was found. Caching addresses across passes caused a use-after-free crash:
// killed enemies are deallocated, the game reuses the memory, and a stale write
// corrupts whatever now lives there. Never cache addresses of transient objects.

public extension Scanner {

    /// Pins player health to max. Returns (componentsTouched, sampleCurrentHP).
    @discardableResult
    static func applyGodmode(_ mem: ProcessMemory) -> (count: Int, sample: Int32?) {
        var count = 0
        var sample: Int32?
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 12 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: Int32.self) == 1 {
                    let m = buf.loadUnaligned(fromByteOffset: i + 4, as: Int32.self)
                    if m == playerMaxHP {
                        let c = buf.loadUnaligned(fromByteOffset: i + 8, as: Int32.self)
                        if c >= 0 && c <= m {
                            if sample == nil { sample = c }
                            if c < m { mem.writeI32(base &+ UInt64(i) &+ 8, m); count += 1 }
                        }
                    }
                }
                i += 4
            }
        }
        return (count, sample)
    }

    /// Drops confirmed enemy types to 1 HP. Returns how many were alive.
    @discardableResult
    static func applyOneHit(_ mem: ProcessMemory, allowed: Set<Int32>? = nil) -> Int {
        let types = allowed ?? knownEnemyMaxHP
        var alive = 0
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 12 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: Int32.self) == 1 {
                    let m = buf.loadUnaligned(fromByteOffset: i + 4, as: Int32.self)
                    if types.contains(m), m != playerMaxHP {
                        let c = buf.loadUnaligned(fromByteOffset: i + 8, as: Int32.self)
                        if c > 1 && c <= m { mem.writeI32(base &+ UInt64(i) &+ 8, 1); alive += 1 }
                    }
                }
                i += 4
            }
        }
        return alive
    }

    /// Tops a weapon's magazine up. Returns entries written.
    @discardableResult
    static func applyWeaponAmmo(_ mem: ProcessMemory, vtable: UInt64,
                                weaponID: Int32, quantity: Int32) -> Int {
        var n = 0
        mem.scanWritableRegions { base, buf in
            var i = 0
            while i + 0x30 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: UInt64.self) == vtable {
                    let item = buf.loadUnaligned(fromByteOffset: i + 0x10, as: Int32.self)
                    let wep = buf.loadUnaligned(fromByteOffset: i + 0x14, as: Int32.self)
                    if item == 0 && wep == weaponID {
                        let q = buf.loadUnaligned(fromByteOffset: i + Int(quantityOffset), as: Int32.self)
                        if q != quantity {
                            mem.writeI32(base &+ UInt64(i) &+ quantityOffset, quantity); n += 1
                        }
                    }
                }
                i += 8
            }
        }
        return n
    }
}
