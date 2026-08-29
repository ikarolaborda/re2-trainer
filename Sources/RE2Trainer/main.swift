import Foundation
import Darwin
import RE2TrainerCore

// re2trainer - CLI front end. The GUI (RE2TrainerGUI) drives the same core.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func attach() -> ProcessMemory {
    if getuid() != 0 { fail("must run as root (task_for_pid). try: sudo re2trainer ...") }
    guard let pid = GameProcess.findPID() else { fail("Resident Evil 2 is not running") }
    guard let mem = ProcessMemory(pid: pid) else { fail("task_for_pid(\(pid)) failed") }
    return mem
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "status" {

case "status":
    let (ok, detail) = GameProcess.verifyBinary()
    print("binary   : \(ok ? "VERIFIED" : "MISMATCH") (\(detail))")
    let mem = attach()
    print("pid      : \(mem.pid)")
    if let base = GameProcess.moduleBase(mem) {
        print("base     : 0x\(String(base, radix: 16))")
    }
    print("resolving type database (102k types, one-time)...")
    if let gt = GameTypes(mem) {
        print("tdb      : v\(gt.db.version)  \(gt.db.numTypes) types  @0x\(String(gt.db.base, radix: 16))")
        let ph = gt.playerHealth(mem)
        if let p = ph.first {
            print("player   : \(p.current)/\(p.maxHP)   [\(RE2.playerHealthType)]  \(ph.count) instance(s)")
        } else {
            print("player   : no instance (in-game with a save loaded?)")
        }
        let eh = gt.enemyHealth(mem)
        print("enemies  : \(eh.count) alive   [\(RE2.enemyHealthType)]")
        let hps = eh.map { $0.maxHP }.sorted()
        if !hps.isEmpty { print("           max HP seen: \(Set(hps).sorted())") }
    } else {
        print("tdb      : not found")
    }
    print("--- legacy signature scan, for comparison ---")
    let player = Scanner.playerHealth(mem)
    if let first = player.first, let cur = mem.readI32(first.currentOffset) {
        print("player   : \(cur)/\(first.maxHP)   (\(player.count) components)")
    } else {
        print("player   : not found — in-game with a save loaded?")
    }
    let enemies = Scanner.enemyHealth(mem).filter { (mem.readI32($0.currentOffset) ?? 0) > 1 }
    print("enemies  : \(enemies.count) alive")
    if let vt = Scanner.itemVTable(mem) {
        print("item vt  : 0x\(String(vt, radix: 16))")
        let mag = Scanner.weaponEntries(mem, vtable: vt, weaponID: Trainer.magnumWeaponID)
        print("magnum   : \(mag.count) entries")
    }

case "godmode":
    let mem = attach()
    print("godmode: pinning player health. ctrl-c to stop.")
    while true {
        if kill(mem.pid, 0) != 0 { print("game exited"); break }
        if SaveGuard.isSaving(mem) { usleep(200_000); continue }
        Scanner.applyGodmode(mem)
        usleep(700_000)
    }

case "onehit":
    let mem = attach()
    print("onehit: dropping enemies to 1 HP. ctrl-c to stop.")
    while true {
        if kill(mem.pid, 0) != 0 { print("game exited"); break }
        if SaveGuard.isSaving(mem) { usleep(200_000); continue }
        let n = Scanner.applyOneHit(mem)
        if n > 0 { print("[pass] \(n) enemies dropped to 1 HP") }
        usleep(700_000)
    }

default:
    print("""
    RE2Trainer — Resident Evil 2, macOS build \(GameProcess.expectedVersion)

    usage: sudo re2trainer <command>
      status    verify binary, report player/enemy/inventory state
      godmode   pin player health to maximum
      onehit    drop all enemies to 1 HP

    GUI: sudo .build/release/RE2TrainerGUI
    """)
}
