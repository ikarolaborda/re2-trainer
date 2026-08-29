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

    @Published public var godmode = false        { didSet { toggle(.godmode, godmode) } }
    @Published public var oneHitKill = false     { didSet { toggle(.oneHit, oneHitKill) } }
    @Published public var infiniteMagnum = false { didSet { toggle(.magnum, infiniteMagnum) } }

    public enum Feature: String { case godmode, oneHit, magnum }

    private var mem: ProcessMemory?
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
        set {
            $0.pid = p; $0.attached = true; $0.binaryVerified = ok
            $0.status = ok ? "Attached to pid \(p)"
                           : "Attached — version mismatch, behaviour undefined"
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
        guard on else { lock.lock(); running.remove(f); lock.unlock(); return }
        guard attached, mem != nil else {
            set { t in
                switch f {
                case .godmode: t.godmode = false
                case .oneHit:  t.oneHitKill = false
                case .magnum:  t.infiniteMagnum = false
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
        var lastScan = Date.distantPast
        var health: [HealthComponent] = []
        var enemies: [HealthComponent] = []
        var vtable: UInt64?
        var magnumEntries: [UInt64] = []

        while isRunning(f) {
            if kill(target, 0) != 0 { set { $0.attached = false; $0.status = "Game exited" }; break }

            // Never write while the game is serializing a save. Doing so froze
            // the game twice: our writes raced SaveThread_SerializeManager as it
            // walked the same structures.
            if SaveGuard.isSaving(mem) {
                set { $0.pausedForSave = true }
                usleep(200_000)
                continue
            }
            set { $0.pausedForSave = false }

            let due = Date().timeIntervalSince(lastScan) > 5

            switch f {
            case .godmode:
                if due { health = Scanner.playerHealth(mem); lastScan = Date() }
                var seen: Int32?
                for h in health {
                    guard let mx = mem.readI32(h.address &+ 4), mx == Scanner.playerMaxHP,
                          let cur = mem.readI32(h.currentOffset), cur >= 0, cur <= mx else { continue }
                    if seen == nil { seen = cur }
                    if cur < mx { mem.writeI32(h.currentOffset, mx) }
                }
                if let v = seen { set { $0.playerHP = "\(v)/\(Scanner.playerMaxHP)" } }

            case .oneHit:
                if due {
                    enemies = Scanner.enemyHealth(mem)
                    lastScan = Date()
                    let n = enemies.count
                    set { $0.enemiesTracked = n }
                }
                for e in enemies {
                    guard let mx = mem.readI32(e.address &+ 4), mx == e.maxHP,
                          let cur = mem.readI32(e.currentOffset), cur > 1, cur <= mx else { continue }
                    mem.writeI32(e.currentOffset, 1)
                }

            case .magnum:
                if due {
                    if vtable == nil { vtable = Scanner.itemVTable(mem) }
                    if let vt = vtable {
                        magnumEntries = Scanner.weaponEntries(mem, vtable: vt, weaponID: Trainer.magnumWeaponID)
                    }
                    lastScan = Date()
                }
                for e in magnumEntries where mem.readI32(e &+ Scanner.quantityOffset) != Trainer.magnumAmmo {
                    mem.writeI32(e &+ Scanner.quantityOffset, Trainer.magnumAmmo)
                }
            }
            usleep(130_000)
        }

        if f == .oneHit { set { $0.enemiesTracked = 0 } }
        if f == .godmode { set { $0.playerHP = "" } }
    }

    public static let magnumWeaponID: Int32 = 31
    public static let magnumAmmo: Int32 = 99
}
