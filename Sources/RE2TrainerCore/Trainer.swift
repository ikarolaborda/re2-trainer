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


    @Published public var godmode = false        { didSet { toggle(.godmode, godmode) } }
    @Published public var oneHitKill = false     { didSet { toggle(.oneHit, oneHitKill) } }
    @Published public var infiniteMagnum = false { didSet { toggle(.magnum, infiniteMagnum) } }

    public enum Feature: String { case godmode, oneHit, magnum }

    private var mem: ProcessMemory?
    private var calibration = Calibration()

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
        if f == .godmode, !calibration.isCalibrated {
            set { t in
                t.godmode = false
                t.calibrationHint = "Calibrate before enabling Godmode"
            }
            return
        }
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
        var vtable: UInt64?

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
                // Only ever write to components calibration proved are the
                // player's. A signature match alone is not evidence: ~45
                // structs match `marker==1, max==1200` and most are not health.
                let (_, valid) = calibration.applyGodmode(mem)
                if valid == 0 {
                    set {
                        $0.godmode = false
                        $0.calibrated = false
                        $0.calibrationHint = "Calibration went stale — recalibrate"
                    }
                    break
                }
                if let v = calibration.sampleHP(mem) {
                    set { $0.playerHP = "\(v)/\(Scanner.playerMaxHP)" }
                }

            case .oneHit:
                let alive = Scanner.applyOneHit(mem)
                set { $0.enemiesTracked = alive }

            case .magnum:
                if vtable == nil { vtable = Scanner.itemVTable(mem) }
                if let vt = vtable {
                    Scanner.applyWeaponAmmo(mem, vtable: vt,
                                            weaponID: Trainer.magnumWeaponID,
                                            quantity: Trainer.magnumAmmo)
                }
            }

            // A full pass reads ~3.5GB, so passes are spaced rather than tight.
            usleep(700_000)
        }

        if f == .oneHit { set { $0.enemiesTracked = 0 } }
        if f == .godmode { set { $0.playerHP = "" } }
    }

    // MARK: - calibration

    /// Step 1: at full health. Snapshots every candidate component.
    public func calibrateStep1() {
        guard let mem else { return }
        calibration.capture(mem)
        set {
            $0.calibrated = false
            $0.calibrationHint = "Baseline taken (\(self.calibration.baseline.count) candidates) — now take one hit"
        }
    }

    /// Step 2: after taking damage. Keeps only components that actually moved.
    public func calibrateStep2() {
        guard let mem else { return }
        let n = calibration.refine(mem)
        set {
            $0.calibrated = n > 0
            $0.calibrationHint = n > 0
                ? "Calibrated: \(n) verified component\(n == 1 ? "" : "s")"
                : "No component moved — take a hit between the two steps"
        }
    }

    public static let magnumWeaponID: Int32 = 31
    public static let magnumAmmo: Int32 = 99
}
