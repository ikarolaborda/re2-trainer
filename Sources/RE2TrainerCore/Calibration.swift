import Foundation

/// Identifies the player's health component by *measurement* rather than by
/// assumption.
///
/// `marker == 1 && max == 1200` looked like a precise signature and is not:
/// a live game contains ~45 matches, several with visible garbage in adjacent
/// fields. Writing to all of them froze the game. The only trustworthy test is
/// behavioural — a component that moves when the player takes damage is the
/// player's; one that doesn't, isn't.
///
/// Usage: capture a baseline at full health, have the player take one hit,
/// then `refine`. Anything that didn't drop is discarded.
public struct Calibration {

    /// address -> current HP, captured at baseline.
    public private(set) var baseline: [UInt64: Int32] = [:]
    /// Components proven to track player damage.
    public private(set) var verified: [UInt64] = []
    public var isCalibrated: Bool { !verified.isEmpty }

    public init() {}

    /// Snapshot every candidate component and its current value.
    public mutating func capture(_ mem: ProcessMemory) {
        var map: [UInt64: Int32] = [:]
        for h in Scanner.playerHealth(mem) {
            if let cur = mem.readI32(h.currentOffset) { map[h.address] = cur }
        }
        baseline = map
        verified = []
    }

    /// Keep only components whose value dropped since `capture` — i.e. the ones
    /// that actually represent the health the player just lost.
    @discardableResult
    public mutating func refine(_ mem: ProcessMemory) -> Int {
        var keep: [UInt64] = []
        for (addr, before) in baseline {
            guard let mx = mem.readI32(addr &+ 4), mx == Scanner.playerMaxHP,
                  let now = mem.readI32(addr &+ 8), now >= 0, now <= mx,
                  now < before
            else { continue }
            keep.append(addr)
        }
        verified = keep
        return keep.count
    }

    /// A calibrated address stays trusted only while it still looks like the
    /// component we verified. Heap churn eventually invalidates them, and a
    /// stale write is exactly what corrupted the game before.
    public func stillValid(_ mem: ProcessMemory, _ addr: UInt64) -> Bool {
        guard let marker = mem.readI32(addr), marker == 1,
              let mx = mem.readI32(addr &+ 4), mx == Scanner.playerMaxHP,
              let cur = mem.readI32(addr &+ 8), cur >= 0, cur <= mx
        else { return false }
        return true
    }

    /// Write max HP to verified components only. Returns (written, stillValid).
    @discardableResult
    public func applyGodmode(_ mem: ProcessMemory) -> (written: Int, valid: Int) {
        var written = 0, valid = 0
        for addr in verified where stillValid(mem, addr) {
            valid += 1
            if let cur = mem.readI32(addr &+ 8), cur < Scanner.playerMaxHP {
                mem.writeI32(addr &+ 8, Scanner.playerMaxHP)
                written += 1
            }
        }
        return (written, valid)
    }

    public func sampleHP(_ mem: ProcessMemory) -> Int32? {
        for addr in verified where stillValid(mem, addr) {
            if let cur = mem.readI32(addr &+ 8) { return cur }
        }
        return nil
    }
}
