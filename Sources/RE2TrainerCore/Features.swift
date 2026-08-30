import Foundation

/// Types and fields for the extended feature set, all resolved from the TDB.
///
/// Offsets here were read out of the type database embedded in the game binary
/// (`TDB\0` at file offset 0x8da47c8, v74, 102,046 types) using the same
/// structure layout as TypeDB.swift. Reading it from disk rather than from the
/// process means type research needs no running game; the offsets are identical
/// either way, and HitPointController's known fields were used to check the
/// offline reader against values already verified live.
public enum RE2Ext {

    /// app.ropeway.survivor.SurvivorCondition — player state flags.
    /// IgnoreBlow suppresses stagger/flinch; IgnoreGrapple prevents grabs.
    public static let survivorConditionType = "app.ropeway.survivor.SurvivorCondition"
    public static let ignoreBlowField: UInt64    = 0x01
    public static let ignoreGrappleField: UInt64 = 0x02

    /// app.ropeway.gamemastering.InventoryManager — typewriter ribbons remaining.
    public static let inventoryManagerType = "app.ropeway.gamemastering.InventoryManager"
    public static let typeWriterRemainField: UInt64 = 0x94

    /// GameSaveData holds the four playtime accumulators. It must be resolved
    /// by *index*, not name: 30 distinct types flatten to the exact full name
    /// "GameSaveData" (nested classes of different outer types), and the
    /// by-name resolver returned one with an unrelated layout, producing
    /// nonsense times. The index is stable because the TDB ships inside the
    /// game binary, whose hash the trainer already verifies.
    public static let gameSaveDataIndex: UInt32 = 27317
    public static let elapsedTimeField: UInt64   = 0x08
    public static let demoTimeField: UInt64      = 0x10
    public static let inventoryTimeField: UInt64 = 0x18
    public static let pauseTimeField: UInt64     = 0x20

    /// app.ropeway.survivor.Inventory — number of usable item slots.
    public static let survivorInventoryType = "app.ropeway.survivor.Inventory"
    public static let currentSlotSizeField: UInt64 = 0x04
    /// Inventory.<Condition> points at the player's SurvivorCondition. Scanning
    /// for SurvivorCondition instances found none, so reach it by pointer.
    public static let conditionField: UInt64 = 0x30
    public static let maxSlotSize: Int32 = 20

    /// app.ropeway.implement.Gun — holds pointers to its parameter blocks.
    public static let gunType = "app.ropeway.implement.Gun"
    public static let recoilParamField: UInt64  = 0x138
    public static let deviateParamField: UInt64 = 0x130

    /// app.ropeway.camera.CameraRecoilParam — per-shot camera kick.
    public static let recoilPitchField: UInt64 = 0x08
    public static let recoilYawField: UInt64   = 0x0c

    /// app.ropeway.DeviateParam — weapon sway. Zeroing the rotation ranges
    /// removes aim wander; the translation ranges remove muzzle drift.
    public static let deviateRanges: [UInt64] = [0x10, 0x18, 0x20, 0x28, 0x30, 0x38]

    /// All types the extended features need, resolved in one pass.
    public static let allTypes: Set<String> = [
        survivorConditionType, inventoryManagerType,
        survivorInventoryType, gunType,
    ]
}

public extension GameTypes {

    /// vt + field base for a named type resolved at attach.
    func resolved(_ name: String, _ mem: ProcessMemory) -> (vt: UInt64, base: UInt64)? {
        guard let idx = extraTypes[name], let vt = db.managedVT(mem, index: idx) else { return nil }
        let b = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        return (vt, b)
    }

    /// Set a byte flag on every live instance of a type.
    @discardableResult
    func setFlag(_ mem: ProcessMemory, type: String, field: UInt64, on: Bool) -> Int {
        guard let r = resolved(type, mem) else { return 0 }
        var n = 0
        for o in db.instances(mem, managedVT: r.vt) {
            if mem.writeU8(o &+ r.base &+ field, on ? 1 : 0) { n += 1 }
        }
        return n
    }

    /// Write an Int32 field on every live instance of a type.
    @discardableResult
    func setI32(_ mem: ProcessMemory, type: String, field: UInt64, value: Int32) -> Int {
        guard let r = resolved(type, mem) else { return 0 }
        var n = 0
        for o in db.instances(mem, managedVT: r.vt) {
            if mem.writeI32(o &+ r.base &+ field, value) { n += 1 }
        }
        return n
    }

    /// Read an Int32 field from every live instance of a type.
    func readI32All(_ mem: ProcessMemory, type: String, field: UInt64) -> [(UInt64, Int32)] {
        guard let r = resolved(type, mem) else { return [] }
        return db.instances(mem, managedVT: r.vt).compactMap { o in
            mem.readI32(o &+ r.base &+ field).map { (o, $0) }
        }
    }

    /// Resolve a type by index, for names that are ambiguous in the TDB.
    func resolvedIndex(_ idx: UInt32, _ mem: ProcessMemory) -> (vt: UInt64, base: UInt64)? {
        guard let vt = db.managedVT(mem, index: idx) else { return nil }
        return (vt, UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt))))
    }

    /// The player's SurvivorCondition, reached through Inventory.<Condition>.
    func survivorConditions(_ mem: ProcessMemory) -> [UInt64] {
        guard let inv = resolved(RE2Ext.survivorInventoryType, mem) else { return [] }
        return db.instances(mem, managedVT: inv.vt).compactMap {
            guard let p = mem.readU64($0 &+ inv.base &+ RE2Ext.conditionField),
                  p > 0x100000000 else { return nil }
            return p
        }
    }

    /// Byte flag on the player's SurvivorCondition.
    @discardableResult
    func setConditionFlag(_ mem: ProcessMemory, field: UInt64, on: Bool) -> Int {
        guard let c = resolved(RE2Ext.survivorConditionType, mem) else { return 0 }
        var n = 0
        for o in survivorConditions(mem) {
            if mem.writeU8(o &+ c.base &+ field, on ? 1 : 0) { n += 1 }
        }
        return n
    }

    // MARK: - features

    @discardableResult
    func setIgnoreBlow(_ mem: ProcessMemory, on: Bool) -> Int {
        setConditionFlag(mem, field: RE2Ext.ignoreBlowField, on: on)
    }

    @discardableResult
    func setIgnoreGrapple(_ mem: ProcessMemory, on: Bool) -> Int {
        setConditionFlag(mem, field: RE2Ext.ignoreGrappleField, on: on)
    }

    /// Top the typewriter ribbon counter back up.
    @discardableResult
    func setInkRibbons(_ mem: ProcessMemory, to n: Int32) -> Int {
        setI32(mem, type: RE2Ext.inventoryManagerType, field: RE2Ext.typeWriterRemainField, value: n)
    }

    func inkRibbons(_ mem: ProcessMemory) -> [(UInt64, Int32)] {
        readI32All(mem, type: RE2Ext.inventoryManagerType, field: RE2Ext.typeWriterRemainField)
    }

    /// Item slots available to the player.
    @discardableResult
    func setSlotSize(_ mem: ProcessMemory, to n: Int32) -> Int {
        setI32(mem, type: RE2Ext.survivorInventoryType, field: RE2Ext.currentSlotSizeField, value: n)
    }

    func slotSize(_ mem: ProcessMemory) -> [(UInt64, Int32)] {
        readI32All(mem, type: RE2Ext.survivorInventoryType, field: RE2Ext.currentSlotSizeField)
    }

    /// Zero a recoil block's Pitch/Yaw, returning the originals so the caller
    /// can put them back. These blocks are shared weapon data rather than
    /// per-shot state, so "off" must restore rather than just stop writing.
    func zeroRecoil(_ mem: ProcessMemory, block: UInt64) -> (pitch: Float, yaw: Float)? {
        guard let vt = mem.readU64(block), vt > 0x100000000 else { return nil }
        let base = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        let pa = block &+ base &+ RE2Ext.recoilPitchField
        let ya = block &+ base &+ RE2Ext.recoilYawField
        guard let p = mem.readU32(pa), let y = mem.readU32(ya) else { return nil }
        let orig = (Float(bitPattern: p), Float(bitPattern: y))
        // Only capture sane originals; a block mid-reload can read as garbage.
        guard orig.0.isFinite, orig.1.isFinite, orig.0 >= 0, orig.0 < 100 else { return nil }
        _ = mem.writeI32(pa, 0)
        _ = mem.writeI32(ya, 0)
        return orig
    }

    func restoreRecoil(_ mem: ProcessMemory, block: UInt64, pitch: Float, yaw: Float) {
        guard let vt = mem.readU64(block), vt > 0x100000000 else { return }
        let base = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        _ = mem.writeI32(block &+ base &+ RE2Ext.recoilPitchField, Int32(bitPattern: pitch.bitPattern))
        _ = mem.writeI32(block &+ base &+ RE2Ext.recoilYawField, Int32(bitPattern: yaw.bitPattern))
    }

    /// Follow Gun's parameter pointers and scale the float fields they hold.
    /// Passing 1.0 restores stock behaviour only if originals were captured;
    /// callers that zero these keep their own snapshot.
    func gunParamBlocks(_ mem: ProcessMemory, field: UInt64) -> [UInt64] {
        guard let r = resolved(RE2Ext.gunType, mem) else { return [] }
        return db.instances(mem, managedVT: r.vt).compactMap {
            guard let p = mem.readU64($0 &+ r.base &+ field), p > 0x100000000 else { return nil }
            return p
        }
    }
}
