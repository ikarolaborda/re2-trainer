import Foundation

/// Reads the RE Engine type database (TDB) out of the running game.
///
/// This replaces every signature heuristic in this project. Instead of guessing
/// which struct is health from its shape — which matched ~45 objects and froze
/// the game when written to — we ask the engine: it ships a table of 102,046
/// types with names, and objects carry a pointer to their type. Player health
/// and enemy health are *different declared types*, so no discrimination is
/// needed at all.
///
/// Structure layout from REFramework (praydog), `shared/sdk/RETypeDB.hpp` and
/// `RETypeDefinition.hpp`. REFramework injects a DLL on Windows; we only need
/// its reverse-engineering of the format, since the TDB is plain data readable
/// through `task_for_pid`.
public struct TypeDB {

    public let base: UInt64
    public let version: UInt32
    public let numTypes: UInt32
    public let types: UInt64
    public let typesImpl: UInt64
    public let stringPool: UInt64

    // sizeof(RETypeDefVersion74) / sizeof(RETypeImpl)
    static let typeDefSize: UInt64 = 0x50
    static let typeImplSize: UInt64 = 0x30

    /// Offsets within the TDB header (v74).
    private enum H {
        static let magic: UInt64      = 0x00
        static let version: UInt64    = 0x04
        static let numTypes: UInt64   = 0x08
        static let types: UInt64      = 0x68
        static let typesImpl: UInt64  = 0x70
        static let stringPool: UInt64 = 0xd8
    }

    /// Locate the TDB by its `TDB\0` magic plus a plausible version.
    public static func find(_ mem: ProcessMemory) -> TypeDB? {
        let magic: UInt32 = 0x0042_4454   // "TDB\0"
        var found: TypeDB?
        mem.scanWritableRegions(minAddress: 0x100000000) { base, buf in
            if found != nil { return }
            var i = 0
            while i + 16 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: UInt32.self) == magic {
                    let ver = buf.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self)
                    let n = buf.loadUnaligned(fromByteOffset: i + 8, as: UInt32.self)
                    if ver >= 60, ver <= 90, n > 1000, n < 500_000 {
                        let addr = base &+ UInt64(i)
                        if let db = TypeDB(mem, at: addr) { found = db; return }
                    }
                }
                i += 4
            }
        }
        return found
    }

    public init?(_ mem: ProcessMemory, at address: UInt64) {
        guard let ver = mem.readU32(address &+ H.version),
              let n = mem.readU32(address &+ H.numTypes),
              let t = mem.readU64(address &+ H.types),
              let ti = mem.readU64(address &+ H.typesImpl),
              let sp = mem.readU64(address &+ H.stringPool),
              t != 0, ti != 0, sp != 0
        else { return nil }
        base = address; version = ver; numTypes = n
        types = t; typesImpl = ti; stringPool = sp
    }

    /// Full name ("namespace.Name") of the type at `index`.
    public func fullName(_ mem: ProcessMemory, index: UInt32) -> String? {
        let td = types &+ UInt64(index) &* Self.typeDefSize
        // RETypeDefVersion74: second 64-bit word packs
        // array_typeid:19, element_typeid:19, impl_index:18, system_typeid:7
        guard let w1 = mem.readU64(td &+ 8) else { return nil }
        let implIndex = (w1 >> 38) & 0x3FFFF

        // RETypeImpl: name_offset (28 bits at 0), namespace_offset (28 bits at 32)
        let ti = typesImpl &+ implIndex &* Self.typeImplSize
        guard let w = mem.readU64(ti) else { return nil }
        let nameOff = UInt64(w & 0x0FFF_FFFF)
        let nsOff = UInt64((w >> 32) & 0x0FFF_FFFF)

        guard let name = mem.readCString(stringPool &+ nameOff), !name.isEmpty else { return nil }
        let ns = mem.readCString(stringPool &+ nsOff) ?? ""
        return ns.isEmpty ? name : "\(ns).\(name)"
    }

    /// Index of a type by exact full name.
    public func indexOf(_ mem: ProcessMemory, fullName wanted: String) -> UInt32? {
        for i in 0..<numTypes {
            if fullName(mem, index: i) == wanted { return i }
        }
        return nil
    }

    /// `managed_vt` (REObjectInfo*) at +0x40 of the type definition. Every
    /// instance of the type begins with a pointer to this, which is how we
    /// enumerate instances without any signature matching.
    public func managedVT(_ mem: ProcessMemory, index: UInt32) -> UInt64? {
        let td = types &+ UInt64(index) &* Self.typeDefSize
        guard let vt = mem.readU64(td &+ 0x40), vt > 0x100000000 else { return nil }
        return vt
    }

    /// All live instances of a type: addresses whose first field is `managedVT`.
    public func instances(_ mem: ProcessMemory, managedVT vt: UInt64) -> [UInt64] {
        var out: [UInt64] = []
        mem.scanWritableRegions(minAddress: 0x200000000) { base, buf in
            var i = 0
            while i + 8 <= buf.count {
                if buf.loadUnaligned(fromByteOffset: i, as: UInt64.self) == vt {
                    out.append(base &+ UInt64(i))
                }
                i += 8
            }
        }
        return out
    }
}

public extension ProcessMemory {
    func readU32(_ address: UInt64) -> UInt32? {
        guard let d = read(address, count: 4) else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    func readCString(_ address: UInt64, max: Int = 256) -> String? {
        guard let d = read(address, count: max) else { return nil }
        guard let z = d.firstIndex(of: 0) else { return nil }
        return String(data: d[..<z], encoding: .utf8)
    }
}
