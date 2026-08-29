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

    private func read(_ mem: ProcessMemory, _ obj: UInt64) -> TypedHealth? {
        guard let marker = mem.readI32(obj &+ RE2.markerOffset), marker == 1,
              let mx = mem.readI32(obj &+ RE2.maxOffset), mx > 0, mx <= 100_000,
              let cur = mem.readI32(obj &+ RE2.curOffset), cur >= 0, cur <= mx
        else { return nil }
        return TypedHealth(object: obj, maxHP: mx, current: cur)
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
        guard let vt = enemyVT else { return [] }
        return db.instances(mem, managedVT: vt)
            .compactMap { read(mem, $0) }
            .filter { $0.current > 0 }
    }
}
