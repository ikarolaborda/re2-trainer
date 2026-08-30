import Foundation

/// RE2-specific knowledge, expressed in the engine's own vocabulary.
///
/// Player and enemy health are distinct declared types, so telling them apart
/// requires no heuristic. Enemy max HP varies widely (890, 830, 770, 740, 200
/// observed in one room), which is why the earlier "all enemies have 620"
/// allow-list silently missed most of them.
public enum RE2 {
    public static let playerHealthType = "app.ropeway.HitPointController"
    public static let enemyHealthType  = "app.ropeway.EnemyHitPointController"

    /// Health fields sit at +0x50 within either controller:
    ///   +0x50 marker(1)   +0x54 max   +0x58 current
    public static let healthFieldOffset: UInt64 = 0x50
    public static let markerOffset: UInt64 = 0x50
    public static let maxOffset: UInt64    = 0x54
    public static let curOffset: UInt64    = 0x58

    /// Non-player HitPointControllers exist (doors and props, max == 2), so
    /// require a plausible character HP to pick the player out.
    public static let minPlayerMaxHP: Int32 = 100

    /// Named fields of app.ropeway.HitPointController, relative to the type's
    /// fieldPtrOffset. The engine has its own invincibility flags — far better
    /// than pinning HP in a loop, which fought the game and raced saves.
    public static let invincibleField: UInt64 = 0x01   // <Invincible>k__BackingField
    public static let noDamageField: UInt64   = 0x02   // <NoDamage>k__BackingField
    public static let defaultHPField: UInt64  = 0x04
    public static let currentHPField: UInt64  = 0x08

    /// Mr. X (em7100) and other bosses. Forcing an EnemyHitPointController's
    /// current HP to 0 puts him on his knees; holding it there keeps him down.
    /// He is distinguished from ordinary enemies by max HP — zombies observed
    /// at 530-890, him at 1100.
    static let bossMinHP: Int32 = 1000

    /// Persistent save counter. The game increments it when saving, so zeroing
    /// it makes the next save write 1 — writing 1 directly gets overwritten.
    static let saveHeaderType = "GameHeaderSaveData"
    static let saveTimesField: UInt64 = 0x50

    /// app.ropeway.GameClock._MeasureGameElapsedTime — clearing it stops the
    /// in-game timer at its current value.
    public static let gameClockType = "app.ropeway.GameClock"
    public static let measureElapsedField: UInt64 = 0x29
}

/// Health resolved through the type database rather than guessed from shape.
public struct TypedHealth {
    public let object: UInt64      // controller instance
    public let maxHP: Int32
    public let current: Int32
    public var currentAddress: UInt64 { object &+ RE2.curOffset }
}

public struct GameTypes {
    public let db: TypeDB
    public private(set) var playerVT: UInt64?
    public private(set) var enemyVT: UInt64?

    public init?(_ mem: ProcessMemory) {
        guard let db = TypeDB.find(mem) else { return nil }
        self.db = db
        // Resolving names walks 102k types, so do it once at attach.
        if let i = db.indexOf(mem, fullName: RE2.playerHealthType) {
            playerVT = db.managedVT(mem, index: i)
        }
        if let i = db.indexOf(mem, fullName: RE2.enemyHealthType) {
            enemyVT = db.managedVT(mem, index: i)
        }
        if playerVT == nil && enemyVT == nil { return nil }
    }

    /// Field base for the player health controller.
    public func playerFieldBase(_ mem: ProcessMemory) -> Int32 {
        guard let vt = playerVT else { return 0 }
        return db.fieldPtrOffset(mem, managedVT: vt)
    }

    /// Set a byte flag on every player health controller.
    @discardableResult
    public func setPlayerFlag(_ mem: ProcessMemory, field: UInt64, on: Bool) -> Int {
        guard let vt = playerVT else { return 0 }
        let base = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        var n = 0
        for h in playerHealth(mem) {
            if mem.writeU8(h.object &+ base &+ field, on ? 1 : 0) { n += 1 }
        }
        return n
    }

    /// Force bosses onto their knees by holding current HP at zero.
    @discardableResult
    func keepBossesDown(_ mem: ProcessMemory) -> Int {
        var n = 0
        for e in enemyHealth(mem) where e.maxHP >= RE2.bossMinHP && e.current > 0 {
            if mem.writeI32(e.currentAddress, 0) { n += 1 }
        }
        return n
    }

    /// Zero the save counter so the next save records 1.
    ///
    /// Found by name (`findfield SaveCount`). The previous attempt at this
    /// intersected 178,360 scan candidates down to 13 and wrote to all of
    /// them; four were `(index, -1)` handle pairs and the game segfaulted.
    @discardableResult
    func resetSaveCount(_ mem: ProcessMemory) -> (written: Int, previous: Int32?) {
        guard let i = db.indexOf(mem, fullName: RE2.saveHeaderType),
              let vt = db.managedVT(mem, index: i) else { return (0, nil) }
        let base = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        var n = 0
        var previous: Int32?
        for obj in db.instances(mem, managedVT: vt) {
            let addr = obj &+ base &+ RE2.saveTimesField
            guard let cur = mem.readI32(addr), cur >= 0, cur < 100_000 else { continue }
            if cur > 0, previous == nil { previous = cur }
            if cur != 0, mem.writeI32(addr, 0) { n += 1 }
        }
        return (n, previous)
    }

    /// Freeze or resume the in-game clock.
    @discardableResult
    public func setGameClock(_ mem: ProcessMemory, running: Bool) -> Int {
        guard let i = db.indexOf(mem, fullName: RE2.gameClockType),
              let vt = db.managedVT(mem, index: i) else { return 0 }
        let base = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        var n = 0
        for obj in db.instances(mem, managedVT: vt) {
            if mem.writeU8(obj &+ base &+ RE2.measureElapsedField, running ? 1 : 0) { n += 1 }
        }
        return n
    }

    /// Reads a health controller.
    ///
    /// Deliberately does NOT require a "marker" byte at +0x00. An early version
    /// did, inferred from Leon's controller before the type database was
    /// available — the TDB shows that offset is where <Invincible>/<NoDamage>
    /// live, not a marker. The check silently rejected 100 of 103 live
    /// controllers, including Ada's, making Godmode look character-specific
    /// when it was just a bad filter.
    private func read(_ mem: ProcessMemory, _ obj: UInt64) -> TypedHealth? {
        guard let mx = mem.readI32(obj &+ RE2.maxOffset), mx > 0, mx <= 100_000,
              let cur = mem.readI32(obj &+ RE2.curOffset), cur >= 0, cur <= mx
        else { return nil }
        return TypedHealth(object: obj, maxHP: mx, current: cur)
    }

    /// Every HitPointController instance, unfiltered.
    public func allPlayerHealth(_ mem: ProcessMemory) -> [TypedHealth] {
        guard let vt = playerVT else { return [] }
        return db.instances(mem, managedVT: vt).compactMap { read(mem, $0) }
    }

    /// The player's health controller. Typically exactly one instance.
    public func playerHealth(_ mem: ProcessMemory) -> [TypedHealth] {
        guard let vt = playerVT else { return [] }
        return db.instances(mem, managedVT: vt)
            .compactMap { read(mem, $0) }
            .filter { $0.maxHP >= RE2.minPlayerMaxHP }
    }

    /// Every living enemy, whatever its max HP.
    public func enemyHealth(_ mem: ProcessMemory) -> [TypedHealth] {
        allEnemyHealth(mem).filter { $0.current > 0 }
    }

    /// Every enemy health controller, including downed ones.
    public func allEnemyHealth(_ mem: ProcessMemory) -> [TypedHealth] {
        guard let vt = enemyVT else { return [] }
        return db.instances(mem, managedVT: vt).compactMap { read(mem, $0) }
    }
}

// MARK: - Inventory
//
// InventoryManager -> CurrentInventory -> _Slots -> Slot._Stock -> DefaultItem
// Every hop is a TDB-named field, so this reaches the one authoritative slot
// list. Earlier signature scanning found ~15 parallel copies of the inventory
// and could not tell which the game actually read, which is why edits kept
// appearing and then vanishing.
public extension RE2 {
    static let inventoryManagerType = "app.ropeway.gamemastering.InventoryManager"
    // InventoryManager (fieldbase 0x50)
    static let currentInventoryField: UInt64 = 0x00
    // app.ropeway.survivor.Inventory (fieldbase 0x50)
    static let slotsField: UInt64 = 0x40
    // System.Collections.Generic.List (fieldbase 0x10): _items, _size
    static let listItemsField: UInt64 = 0x00
    static let listSizeField: UInt64  = 0x08
    static let arrayFirstElement: UInt64 = 0x20
    // app.ropeway.inventory.Slot (fieldbase 0x10) -> StockItem (0x10) -> PrimitiveItem (0x10)
    static let slotStockField: UInt64 = 0x00
    static let stockDefaultItemField: UInt64 = 0x00
    // PrimitiveItem
    static let itemIdField: UInt64    = 0x00
    static let weaponIdField: UInt64  = 0x04
    static let partsField: UInt64     = 0x08
    static let bulletIdField: UInt64  = 0x0c
    static let countField: UInt64     = 0x10
    static let objectFieldBase: UInt64 = 0x10
}

public struct InventorySlot {
    public let slot: UInt64
    public let primitive: UInt64
    public let itemId: Int32
    public let weaponId: Int32
    public let bulletId: Int32
    public let count: Int32
    public var countAddress: UInt64 { primitive &+ RE2.objectFieldBase &+ RE2.countField }
    public var itemIdAddress: UInt64 { primitive &+ RE2.objectFieldBase &+ RE2.itemIdField }
    public var isEmpty: Bool { itemId == 0 && weaponId <= 0 }
}

public extension GameTypes {
    /// The player's live inventory slots, via the type database.
    func inventorySlots(_ mem: ProcessMemory) -> [InventorySlot] {
        guard let mi = db.indexOf(mem, fullName: RE2.inventoryManagerType),
              let mvt = db.managedVT(mem, index: mi) else { return [] }
        let mbase = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: mvt)))
        guard let manager = db.instances(mem, managedVT: mvt).first,
              let inv = mem.readU64(manager &+ mbase &+ RE2.currentInventoryField), inv != 0,
              let slots = mem.readU64(inv &+ 0x50 &+ RE2.slotsField), slots != 0,
              let arr = mem.readU64(slots &+ 0x10 &+ RE2.listItemsField), arr != 0,
              let size = mem.readI32(slots &+ 0x10 &+ RE2.listSizeField), size > 0, size < 256
        else { return [] }

        var out: [InventorySlot] = []
        for i in 0..<Int(size) {
            guard let slot = mem.readU64(arr &+ RE2.arrayFirstElement &+ UInt64(i) * 8), slot != 0,
                  let stock = mem.readU64(slot &+ RE2.objectFieldBase &+ RE2.slotStockField), stock != 0,
                  let prim = mem.readU64(stock &+ RE2.objectFieldBase &+ RE2.stockDefaultItemField), prim != 0,
                  let item = mem.readI32(prim &+ RE2.objectFieldBase &+ RE2.itemIdField),
                  let wep = mem.readI32(prim &+ RE2.objectFieldBase &+ RE2.weaponIdField),
                  let bullet = mem.readI32(prim &+ RE2.objectFieldBase &+ RE2.bulletIdField),
                  let count = mem.readI32(prim &+ RE2.objectFieldBase &+ RE2.countField)
            else { continue }
            out.append(InventorySlot(slot: slot, primitive: prim, itemId: item,
                                     weaponId: wep, bulletId: bullet, count: count))
        }
        return out
    }

    /// Keep a weapon's magazine topped up.
    ///
    /// RE2 has no infinite-ammo flag — no `Infinite`/`Unlimited` string exists
    /// anywhere in its type database. The six bonus weapons are special-cased
    /// in code by weapon ID, so any other weapon can only be *pinned*.
    @discardableResult
    func topUpWeapon(_ mem: ProcessMemory, weaponId: Int32, to count: Int32) -> Int {
        var n = 0
        for s in inventorySlots(mem) where s.weaponId == weaponId && s.count != count {
            if mem.writeI32(s.countAddress, count) { n += 1 }
        }
        return n
    }
}
