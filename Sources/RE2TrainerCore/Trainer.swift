import Foundation
import Combine

/// Engine behind the GUI toggles.
///
/// Every feature is signature-based: it finds its targets by struct *shape*
/// rather than by address or offset. That decision was forced by evidence --
/// a set of 61 static pointer chains to player health resolved perfectly
/// through one game restart and through none of the next. Struct shapes have
/// been stable across every session observed; offsets have not.
///
/// Each loop keeps a cache and re-scans periodically, because a full scan is
/// ~3.5GB and must not run at tick frequency.
public final class Trainer: ObservableObject {

    @Published public private(set) var attached = false
    @Published public private(set) var pid: pid_t = 0
    @Published public private(set) var status = "Not attached"
    @Published public private(set) var playerHP = ""
    @Published public private(set) var enemiesTracked = 0
    @Published public private(set) var binaryVerified = false
    @Published public private(set) var pausedForSave = false
    @Published public private(set) var calibrated = false
    @Published public private(set) var calibrationHint = "Not calibrated"
    @Published public private(set) var saveCountStatus = ""


    @Published public var godmode = false        { didSet { toggle(.godmode, godmode) } }
    @Published public var oneHitKill = false     { didSet { toggle(.oneHit, oneHitKill) } }
    @Published public var infiniteMagnum = false { didSet { toggle(.magnum, infiniteMagnum) } }

    /// Engine-native flags. Unlike the HP-pinning loops these are simply set:
    /// the game honours them itself, so nothing races the engine or a save.
    @Published public var invincible = false { didSet { toggle(.invincible, invincible) } }
    @Published public var noDamage   = false { didSet { toggle(.noDamage, noDamage) } }
    @Published public var freezeTimer = false { didSet { toggle(.freezeTimer, freezeTimer) } }

    /// Holds bosses (Mr. X) at 0 HP so they stay on their knees.
    @Published public var bossesDown = false { didSet { toggle(.bossesDown, bossesDown) } }

    public enum Feature: String { case godmode, oneHit, magnum, invincible, noDamage, freezeTimer, bossesDown }

    private var mem: ProcessMemory?
    private var gameTypes: GameTypes?

    private var running: Set<Feature> = []
    private let queue = DispatchQueue(label: "trainer.loops", attributes: .concurrent)
    private let lock = NSLock()

    public init() {}

    // MARK: - attach

    @discardableResult
    public func attach() -> Bool {
        guard getuid() == 0 else { set { $0.status = "Needs root — relaunch with sudo" }; return false }
        guard let p = GameProcess.findPID() else {
            set { $0.status = "Game not running"; $0.attached = false; $0.pid = 0 }
            mem = nil; return false
        }
        guard let m = ProcessMemory(pid: p) else {
            set { $0.status = "task_for_pid failed"; $0.attached = false }; return false
        }
        let (ok, _) = GameProcess.verifyBinary()
        mem = m
        set { $0.status = "Resolving type database…" }
        gameTypes = GameTypes(m)
        set {
            $0.pid = p; $0.attached = true; $0.binaryVerified = ok
            if self.gameTypes == nil {
                $0.status = "Attached, but type database not found"
            } else if !ok {
                $0.status = "Attached — version mismatch, behaviour undefined"
            } else {
                $0.status = "Attached to pid \(p) · TDB v\(self.gameTypes!.db.version)"
            }
            $0.calibrated = self.gameTypes != nil
            $0.calibrationHint = self.gameTypes != nil
                ? "Types resolved — no calibration needed"
                : "Type database unavailable"
        }
        return true
    }

    private func set(_ mutate: @escaping (Trainer) -> Void) {
        if Thread.isMainThread { mutate(self) }
        else { DispatchQueue.main.async { [weak self] in guard let s = self else { return }; mutate(s) } }
    }

    // MARK: - loop control

    private func isRunning(_ f: Feature) -> Bool {
        lock.lock(); defer { lock.unlock() }; return running.contains(f)
    }

    private func toggle(_ f: Feature, _ on: Bool) {
        guard on else {
            lock.lock(); running.remove(f); lock.unlock()
            // Clearing a flag must actually clear it in the game.
            if let mem, let gt = gameTypes {
                switch f {
                case .invincible:  gt.setPlayerFlag(mem, field: RE2.invincibleField, on: false)
                case .noDamage:    gt.setPlayerFlag(mem, field: RE2.noDamageField, on: false)
                case .freezeTimer: gt.setGameClock(mem, running: true)
                default: break
                }
            }
            return
        }
        if f == .godmode, gameTypes == nil {
            set { t in
                t.godmode = false
                t.calibrationHint = "Type database unavailable — cannot enable"
            }
            return
        }
        guard attached, mem != nil else {
            set { t in
                switch f {
                case .godmode: t.godmode = false
                case .oneHit:  t.oneHitKill = false
                case .magnum:  t.infiniteMagnum = false
                case .invincible:  t.invincible = false
                case .noDamage:    t.noDamage = false
                case .freezeTimer: t.freezeTimer = false
                case .bossesDown:  t.bossesDown = false
                }
            }
            return
        }
        lock.lock(); running.insert(f); lock.unlock()
        queue.async { [weak self] in self?.run(f) }
    }

    // MARK: - feature loops

    private func run(_ f: Feature) {
        guard let mem else { return }
        let target = pid

        while isRunning(f) {
            if kill(target, 0) != 0 { set { $0.attached = false; $0.status = "Game exited" }; break }

            // Never write while the game is serializing a save: our writes raced
            // SaveThread_SerializeManager walking the same structures and froze
            // the game twice.
            if SaveGuard.isSaving(mem) {
                set { $0.pausedForSave = true }
                usleep(200_000)
                continue
            }
            set { $0.pausedForSave = false }

            // Each pass scans and writes in one traversal. Addresses are never
            // reused across passes -- killed enemies are freed and their memory
            // recycled, so a cached write lands in someone else's object. That
            // caused a use-after-free crash (EXC_BAD_ACCESS at 0x12).
            switch f {
            case .godmode:
                // Instances of app.ropeway.HitPointController, as declared by
                // the engine. Typically exactly one, versus ~37 for a shape
                // heuristic — and writing to those 37 froze the game.
                guard let gt = gameTypes else { break }
                let hs = gt.playerHealth(mem)
                for h in hs where h.current < h.maxHP {
                    mem.writeI32(h.currentAddress, h.maxHP)
                }
                if let p = hs.first { set { $0.playerHP = "\(p.current)/\(p.maxHP)" } }

            case .oneHit:
                // Every app.ropeway.EnemyHitPointController instance, whatever
                // its max HP. Enemy HP varies (560/770/830/890 seen in one
                // room), so the old fixed allow-list missed most of them.
                guard let gt = gameTypes else { break }
                let es = gt.enemyHealth(mem)
                for e in es where e.current > 1 {
                    mem.writeI32(e.currentAddress, 1)
                }
                set { $0.enemiesTracked = es.count }

            case .bossesDown:
                _ = gameTypes?.keepBossesDown(mem)

            case .invincible:
                _ = gameTypes?.setPlayerFlag(mem, field: RE2.invincibleField, on: true)

            case .noDamage:
                _ = gameTypes?.setPlayerFlag(mem, field: RE2.noDamageField, on: true)

            case .freezeTimer:
                _ = gameTypes?.setGameClock(mem, running: false)

            case .magnum:
                // RE2 has no infinite-ammo flag — no "Infinite"/"Unlimited"
                // string exists anywhere in its type database. The six bonus
                // weapons are special-cased in code by weapon ID, so any other
                // weapon can only be topped up. Reached through the one
                // authoritative slot list rather than scattered copies.
                _ = gameTypes?.topUpWeapon(mem, weaponId: Trainer.magnumWeaponID,
                                           to: Trainer.magnumAmmo)
            }

            // A full pass reads ~3.5GB, so passes are spaced rather than tight.
            usleep(700_000)
        }

        if f == .oneHit { set { $0.enemiesTracked = 0 } }
        if f == .godmode { set { $0.playerHP = "" } }
    }

    // MARK: - calibration

    /// Zero the save counter. One-shot: save afterwards and it records 1.
    public func resetSaveCount() {
        guard let mem, let gt = gameTypes else {
            set { $0.saveCountStatus = "Not attached" }
            return
        }
        let (n, prev) = gt.resetSaveCount(mem)
        set {
            $0.saveCountStatus = n > 0
                ? "Was \(prev.map(String.init) ?? "?") — now save, it will record 1"
                : "Save counter already 0 — save to record 1"
        }
    }

    public static let magnumWeaponID: Int32 = 31
    public static let magnumAmmo: Int32 = 99
}
