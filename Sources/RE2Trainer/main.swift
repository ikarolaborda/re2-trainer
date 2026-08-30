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

case "types":
    // Search the type database by name substring.
    guard args.count > 2 else { fail("usage: re2trainer types <substring>") }
    let needle = args[2]
    let mem = attach()
    guard let db = TypeDB.find(mem) else { fail("type database not found") }
    print("searching \(db.numTypes) types for \"\(needle)\"…")
    var shown = 0
    for i in 0..<db.numTypes where shown < 40 {
        guard let n = db.fullName(mem, index: i), n.localizedCaseInsensitiveContains(needle) else { continue }
        let live = db.managedVT(mem, index: i).map { db.instances(mem, managedVT: $0).count } ?? 0
        print("  [\(i)] \(n)\(live > 0 ? "   <- \(live) LIVE" : "")")
        shown += 1
    }

case "players":
    // Every HitPointController instance, unfiltered — used to find the
    // player's max HP, which differs per character (Leon 1200, Ada differs).
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let all = gt.allPlayerHealth(mem)
    print("app.ropeway.HitPointController instances: \(all.count)")
    var byMax: [Int32: Int] = [:]
    for h in all { byMax[h.maxHP, default: 0] += 1 }
    for (mx, n) in byMax.sorted(by: { $0.key > $1.key }) {
        let sample = all.first { $0.maxHP == mx }
        print("  max=\(mx)  x\(n)   e.g. cur=\(sample?.current ?? -1)")
    }

case "inv":
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let slots = gt.inventorySlots(mem)
    print("slots: \(slots.count)")
    for (i, s) in slots.enumerated() {
        let what = s.weaponId > 0 ? "weapon \(s.weaponId)"
                 : (s.itemId > 0 ? "item \(s.itemId)" : "empty")
        print(String(format: "  %2d  %-12@  bullet=%d  count=%d", i, what as NSString, s.bulletId, s.count))
    }

case "give":
    // Puts the six infinite weapons into empty inventory slots.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    // weaponId : bulletId
    let wanted: [(Int32, Int32)] = [
        (82, 15),   // Samurai Edge (Infinite)
        (23, 17),   // LE 5 (Infinite)
        (47, 0),    // Combat Knife (Infinite)
        (222, 15),  // ATM-4 (Infinite)
        (242, 15),  // Anti-tank Rocket (Infinite)
        (252, 15),  // Minigun (Infinite)
    ]
    var idx = 0
    var placed = 0
    for s in gt.inventorySlots(mem) where idx < wanted.count {
        guard s.isEmpty else { continue }
        let (w, b) = wanted[idx]
        let base = s.primitive &+ RE2.objectFieldBase
        mem.writeI32(base &+ RE2.itemIdField, 0)
        mem.writeI32(base &+ RE2.weaponIdField, w)
        mem.writeI32(base &+ RE2.partsField, 0)
        mem.writeI32(base &+ RE2.bulletIdField, b)
        mem.writeI32(base &+ RE2.countField, 99)
        print("  slot -> weapon \(w) (bullet \(b), count 99)")
        idx += 1; placed += 1
    }
    print(placed > 0 ? "placed \(placed) weapons" : "no empty slots — drop something first")

default:
    print("""
    RE2Trainer — Resident Evil 2, macOS build \(GameProcess.expectedVersion)

    usage: sudo re2trainer <command>
      status    verify binary, report player/enemy/inventory state
      godmode   pin player health to maximum
      onehit    drop all enemies to 1 HP
      inv       list the player's inventory slots
      give      put the six infinite weapons into empty slots

    GUI: sudo .build/release/RE2TrainerGUI
    """)
}
