import Foundation
import Darwin

// RE2Trainer - a pointer-chain trainer for the Mac App Store build of
// Resident Evil 2 (2019).  Requires root for task_for_pid.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// Walks the verified chains and returns the first that points at a real
/// health component (marker==1, max==1200).  Chain redundancy is the whole
/// robustness strategy: no single chain is a point of failure.
func resolveHealth(_ mem: ProcessMemory, base: UInt64) -> (addr: UInt64, chain: Chain)? {
    for chain in Offsets.healthChains {
        guard let addr = chain.resolve(mem, moduleBase: base),
              let marker = mem.readI32(addr),
              let maxHP = mem.readI32(addr &+ Offsets.healthMaxOffset),
              let cur = mem.readI32(addr &+ Offsets.healthCurOffset)
        else { continue }
        if marker == 1 && maxHP == Offsets.maxHP && cur >= 0 && cur <= maxHP {
            return (addr, chain)
        }
    }
    return nil
}

func attach() -> (ProcessMemory, UInt64) {
    if getuid() != 0 { fail("must run as root (task_for_pid). try: sudo re2trainer ...") }
    guard let pid = GameProcess.findPID() else { fail("Resident Evil 2 is not running") }
    guard let mem = ProcessMemory(pid: pid) else { fail("task_for_pid(\(pid)) failed") }
    guard let base = GameProcess.moduleBase(mem) else { fail("could not locate module base") }
    return (mem, base)
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "status"

switch cmd {
case "status":
    let (ok, detail) = GameProcess.verifyBinary()
    print("binary   : \(ok ? "VERIFIED" : "MISMATCH") (\(detail))")
    if !ok { print("           offsets were derived from \(GameProcess.expectedVersion); results undefined") }
    let (mem, base) = attach()
    print("pid      : \(mem.pid)")
    print("base     : 0x\(String(base, radix: 16))")
    if let (addr, chain) = resolveHealth(mem, base: base) {
        let cur = mem.readI32(addr &+ Offsets.healthCurOffset) ?? -1
        let mx  = mem.readI32(addr &+ Offsets.healthMaxOffset) ?? -1
        print("health   : 0x\(String(addr, radix: 16))  \(cur)/\(mx)")
        print("via      : 0x\(String(chain.anchor, radix: 16)) -> " +
              chain.offsets.map { "+0x" + String($0, radix: 16) }.joined(separator: " -> "))
    } else {
        print("health   : not resolved (are you in-game with a save loaded?)")
    }

case "godmode":
    let (mem, base) = attach()
    print("godmode: pinning health to \(Offsets.maxHP). ctrl-c to stop.")
    var topups = 0
    var lastReport = Date()
    while true {
        if kill(mem.pid, 0) != 0 { print("game exited"); break }
        if let (addr, _) = resolveHealth(mem, base: base) {
            if let cur = mem.readI32(addr &+ Offsets.healthCurOffset), cur < Offsets.maxHP {
                mem.writeI32(addr &+ Offsets.healthCurOffset, Offsets.maxHP)
                topups += 1
            }
        }
        if Date().timeIntervalSince(lastReport) > 15 {
            print("[status] topups=\(topups)")
            lastReport = Date()
        }
        usleep(100_000)
    }

default:
    print("""
    RE2Trainer - Resident Evil 2 (macOS, Mac App Store build \(GameProcess.expectedVersion))

    usage: sudo re2trainer <command>
      status    verify binary, resolve health via pointer chains, print state
      godmode   keep player health pinned at maximum
    """)
}
