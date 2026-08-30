import Foundation
import Darwin
import RE2TrainerCore

// re2trainer - CLI front end. The GUI (RE2TrainerGUI) drives the same core.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// Commands that write engine flags the GUI also asserts. Running these while
/// the GUI holds state produces a change that is reverted within a second, so
/// they are refused rather than silently lost.
let guiOwnedCommands: Set<String> = ["flags", "clock", "stagger", "grapple"]

func checkOwnership(_ cmd: String) {
    guard guiOwnedCommands.contains(cmd), let pid = Ownership.heldBy() else { return }
    if CommandLine.arguments.contains("--force") {
        FileHandle.standardError.write("warning: GUI (pid \(pid)) owns this state; --force given, it will re-assert within ~1s\n".data(using: .utf8)!)
        return
    }
    fail("""
    the GUI trainer (pid \(pid)) owns this state and will revert this change.
      use its toggle instead, quit it, or pass --force
    """)
}

func attach() -> ProcessMemory {
    if getuid() != 0 { fail("must run as root (task_for_pid). try: sudo re2trainer ...") }
    guard let pid = GameProcess.findPID() else { fail("Resident Evil 2 is not running") }
    guard let mem = ProcessMemory(pid: pid) else { fail("task_for_pid(\(pid)) failed") }
    return mem
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "status"
checkOwnership(command)
switch command {

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

case "pinaddr":
    // pinaddr <addr> <int32bits> [ms] — holds a raw address at a value.
    // Used for the incinerator countdown (a float frame counter).
    guard args.count > 3 else { fail("usage: re2trainer pinaddr <addr> <int32> [ms]") }
    let mem = attach()
    let addr = UInt64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
    let v = Int32(args[3]) ?? 0
    let ms = args.count > 4 ? (UInt32(args[4]) ?? 100) : 100
    print("pinning 0x\(String(addr, radix: 16)) to \(v). ctrl-c to stop.")
    var n = 0
    while true {
        if kill(mem.pid, 0) != 0 { print("game exited"); break }
        if mem.readI32(addr) != v { mem.writeI32(addr, v); n += 1 }
        usleep(ms * 1000)
    }

case "pin":
    // Keeps every carried weapon topped up. ctrl-c to stop.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let count: Int32 = args.count > 2 ? (Int32(args[2]) ?? 99) : 99
    print("pinning all weapons to \(count). ctrl-c to stop.")
    while true {
        if kill(mem.pid, 0) != 0 { print("game exited"); break }
        if SaveGuard.isSaving(mem) { usleep(200_000); continue }
        gt.topUpAllWeapons(mem, to: count)
        usleep(400_000)
    }

case "topup":
    // topup <weaponId> <count> — writes PrimitiveItem.Count for that weapon.
    guard args.count > 3, let w = Int32(args[2]), let c = Int32(args[3]) else {
        fail("usage: re2trainer topup <weaponId> <count>")
    }
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let n = gt.topUpWeapon(mem, weaponId: w, to: c)
    print("  weapon \(w) -> \(c)  (\(n) slot(s) written)")

case "clearweapon":
    // Removes a weapon from the inventory (its model may not exist in this
    // scenario, in which case it equips but renders nothing).
    guard args.count > 2, let w = Int32(args[2]) else { fail("usage: re2trainer clearweapon <weaponId>") }
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    var n = 0
    for s in gt.inventorySlots(mem) where s.weaponId == w {
        let base = s.primitive &+ RE2.objectFieldBase
        mem.writeI32(base &+ RE2.itemIdField, 0)
        mem.writeI32(base &+ RE2.weaponIdField, -1)
        mem.writeI32(base &+ RE2.bulletIdField, 0)
        mem.writeI32(base &+ RE2.countField, 0)
        n += 1
    }
    print("  cleared weapon \(w) from \(n) slot(s)")

case "poke":
    guard args.count > 3 else { fail("usage: re2trainer poke <addr> <int32>") }
    let mem = attach()
    let addr = UInt64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
    let v = Int32(args[3]) ?? 0
    let before = mem.readI32(addr).map(String.init) ?? "?"
    mem.writeI32(addr, v)
    print("  0x\(String(addr, radix: 16)): \(before) -> \(mem.readI32(addr).map(String.init) ?? "?")")

case "str":
    // Search memory for an ASCII or UTF-16 string.
    guard args.count > 2 else { fail("usage: re2trainer str <text> [utf16] [max]") }
    let needle = args[2]
    let utf16 = args.contains("utf16")
    let maxHits = Int(args.last ?? "") ?? 20
    let mem = attach()
    var pat = [UInt8]()
    for ch in needle.utf8 { pat.append(ch); if utf16 { pat.append(0) } }
    var hits = 0
    mem.scanWritableRegions(minAddress: 0x100000000) { base, buf in
        if hits >= maxHits { return }
        var i = 0
        while i + pat.count <= buf.count && hits < maxHits {
            if buf.loadUnaligned(fromByteOffset: i, as: UInt8.self) == pat[0] {
                var ok = true
                for k in 1..<pat.count where buf.loadUnaligned(fromByteOffset: i+k, as: UInt8.self) != pat[k] { ok = false; break }
                if ok {
                    let start = max(0, i - 24)
                    var ctx = ""
                    for k in start..<min(buf.count, i + pat.count + 24) {
                        let c = buf.loadUnaligned(fromByteOffset: k, as: UInt8.self)
                        ctx += (c >= 32 && c < 127) ? String(UnicodeScalar(c)) : "."
                    }
                    print("  0x\(String(base &+ UInt64(i), radix: 16))  \(ctx)")
                    hits += 1
                }
            }
            i += 1
        }
    }
    print("  \(hits) hit(s)")

case "peek":
    guard args.count > 2 else { fail("usage: re2trainer peek <addr> [count]") }
    let mem = attach()
    let addr = UInt64(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
    let n = args.count > 3 ? Int(args[3]) ?? 16 : 16
    for i in 0..<n {
        let a = addr &+ UInt64(i) * 4
        let v = mem.readI32(a).map(String.init) ?? "?"
        let q = mem.readU64(a).map { "0x" + String($0, radix: 16) } ?? "?"
        print(String(format: "  +0x%03x  0x%llx  i32=%@  u64=%@", i*4, a, v as NSString, q as NSString))
    }

case "findfield":
    // Search every type's fields for a name substring — the tool that found
    // the save counter. Prints only types that have live instances by default.
    guard args.count > 2 else { fail("usage: re2trainer findfield <substring> [all]") }
    let needle = args[2]
    let liveOnly = !(args.count > 3 && args[3] == "all")
    let mem = attach()
    guard let db = TypeDB.find(mem) else { fail("type database not found") }
    print("searching \(db.numTypes) types for field \"\(needle)\"\(liveOnly ? " (live only)" : "")…")
    var hits = 0
    for i in 0..<db.numTypes where hits < 40 {
        let fs = db.fields(mem, index: i).filter { $0.name.localizedCaseInsensitiveContains(needle) }
        guard !fs.isEmpty else { continue }
        let vt = db.managedVT(mem, index: i)
        let live = vt.map { db.instances(mem, managedVT: $0).count } ?? 0
        if liveOnly && live == 0 { continue }
        let nm = db.fullName(mem, index: i) ?? "?"
        let fpo = vt.map { db.fieldPtrOffset(mem, managedVT: $0) } ?? 0
        print("  [\(i)] \(nm)   fieldbase=0x\(String(fpo, radix: 16))  \(live) live")
        for f in fs { print(String(format: "     +0x%04x  %@", f.offset, f.name as NSString)) }
        hits += 1
    }
    print("  \(hits) type(s)")

case "insts":
    // List every instance of a type (fields only shows the first).
    guard args.count > 2 else { fail("usage: re2trainer insts <type substring> [fieldOffset]") }
    let mem = attach()
    guard let db = TypeDB.find(mem) else { fail("type database not found") }
    let off = args.count > 3 ? (UInt64(args[3].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0) : 0
    let exactIndex = UInt32(args[2])
    for i in 0..<db.numTypes {
        if let ix = exactIndex { if i != ix { continue } }
        else { guard let n = db.fullName(mem, index: i), n.localizedCaseInsensitiveContains(args[2]) else { continue } }
        guard let vt = db.managedVT(mem, index: i) else { continue }
        let fpo = UInt64(bitPattern: Int64(db.fieldPtrOffset(mem, managedVT: vt)))
        let insts = db.instances(mem, managedVT: vt)
        guard !insts.isEmpty else { continue }
        print("\(db.fullName(mem, index: i) ?? "?")  fieldbase=0x\(String(fpo, radix: 16))  \(insts.count) instances")
        for o in insts.prefix(24) {
            if off != 0, let v = mem.readU64(o &+ fpo &+ off) {
                print("  0x\(String(o, radix: 16))   +0x\(String(off, radix: 16)) = 0x\(String(v, radix: 16))")
            } else {
                print("  0x\(String(o, radix: 16))")
            }
        }
        break
    }

case "fields":
    guard args.count > 2 else { fail("usage: re2trainer fields <type name substring>") }
    let mem = attach()
    guard let db = TypeDB.find(mem) else { fail("type database not found") }
    var found = 0
    for i in 0..<db.numTypes where found < 3 {
        guard let n = db.fullName(mem, index: i), n.localizedCaseInsensitiveContains(args[2]) else { continue }
        let live = db.managedVT(mem, index: i).map { db.instances(mem, managedVT: $0) } ?? []
        let fpo = db.managedVT(mem, index: i).map { db.fieldPtrOffset(mem, managedVT: $0) } ?? 0
        print("[\(i)] \(n)   fieldbase=0x\(String(fpo, radix: 16))  \(live.count) live")
        for (nm, off) in db.fields(mem, index: i).sorted(by: { $0.offset < $1.offset }) {
            print(String(format: "   +0x%04x  %@", off, nm as NSString))
        }
        if let first = live.first { print("   e.g. instance 0x\(String(first, radix: 16))") }
        found += 1
    }

case "clock":
    // clock 1 = run, clock 0 = freeze. Sets GameClock._MeasureGameElapsedTime.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let run = args.count > 2 ? (args[2] != "0") : true
    let n = gt.setGameClock(mem, running: run)
    print("  game clock \(run ? "RUNNING" : "FROZEN") on \(n) instance(s)")

case "flags":
    // Read (and optionally set) the player's Invincible / NoDamage flags.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let base = UInt64(bitPattern: Int64(gt.playerFieldBase(mem)))
    let hs = gt.playerHealth(mem)
    if hs.isEmpty { print("no player health controller"); break }
    if args.count > 2, let v = Int32(args[2]) {
        let n1 = gt.setPlayerFlag(mem, field: RE2.invincibleField, on: v != 0)
        let n2 = gt.setPlayerFlag(mem, field: RE2.noDamageField, on: v != 0)
        print("set Invincible/NoDamage = \(v) on \(n1)/\(n2) controller(s)")
    }
    for h in hs {
        let inv = mem.read(h.object &+ base &+ RE2.invincibleField, count: 1)?.first ?? 255
        let nod = mem.read(h.object &+ base &+ RE2.noDamageField, count: 1)?.first ?? 255
        print("  0x\(String(h.object, radix: 16))  hp=\(h.current)/\(h.maxHP)  Invincible=\(inv)  NoDamage=\(nod)")
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

case "box":
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let slots = gt.boxSlots(mem)
    if slots.isEmpty { print("box list empty — open the item box in-game"); break }
    var occupied = 0
    print("box slots: \(slots.count)")
    for (i, s) in slots.enumerated() where !s.isEmpty {
        print("  \(i)  \(s.weaponId > 0 ? "weapon \(s.weaponId)" : "item \(s.itemId)")  count=\(s.count)")
        occupied += 1
        if occupied > 60 { print("  …"); break }
    }
    print("occupied: \(slots.filter { !$0.isEmpty }.count) / \(slots.count)")

case "boxgive":
    // Puts the six genuinely-infinite weapons into empty box slots.
    // These are infinite because the game special-cases those weapon IDs —
    // unlike a high Count, which reverts to the real magazine on equip.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let wanted: [(Int32, Int32)] = [(82,15),(23,17),(47,0),(222,15),(242,15),(252,15)]
    let slots = gt.boxSlots(mem)
    if slots.isEmpty { print("box list empty — open the item box in-game"); break }
    let present = Set(slots.filter { $0.weaponId > 0 }.map { $0.weaponId })
    var todo = wanted.filter { !present.contains($0.0) }
    var placed = 0
    for s in slots where !todo.isEmpty && s.isEmpty {
        let (w, b) = todo.removeFirst()
        let base = s.primitive &+ RE2.objectFieldBase
        mem.writeI32(base &+ RE2.itemIdField, 0)
        mem.writeI32(base &+ RE2.weaponIdField, w)
        mem.writeI32(base &+ RE2.partsField, 0)
        mem.writeI32(base &+ RE2.bulletIdField, b)
        mem.writeI32(base &+ RE2.countField, 99)
        print("  -> weapon \(w)")
        placed += 1
    }
    print("placed \(placed); already present: \(present.intersection(Set(wanted.map { $0.0 })).sorted())")

case "boxadd":
    // boxadd <id>[:count],<id>… — place item IDs into empty box slots.
    guard args.count > 2 else { fail("usage: re2trainer boxadd <id[:count]>,…") }
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let specs: [(Int32, Int32)] = args[2].split(separator: ",").compactMap {
        let p = $0.split(separator: ":")
        guard let id = Int32(p[0]) else { return nil }
        return (id, p.count > 1 ? (Int32(p[1]) ?? 1) : 1)
    }
    let slots = gt.boxSlots(mem)
    if slots.isEmpty { print("box list empty — open the item box in-game"); break }
    var todo = specs
    var placed = 0
    for s in slots where !todo.isEmpty && s.isEmpty {
        let (id, c) = todo.removeFirst()
        let base = s.primitive &+ RE2.objectFieldBase
        mem.writeI32(base &+ RE2.itemIdField, id)
        mem.writeI32(base &+ RE2.weaponIdField, -1)
        mem.writeI32(base &+ RE2.partsField, 0)
        mem.writeI32(base &+ RE2.bulletIdField, 0)
        mem.writeI32(base &+ RE2.countField, c)
        print("  -> item \(id) x\(c)")
        placed += 1
    }
    print("placed \(placed)")

case "boxtrim":
    // Keeps the infinite weapons plus an explicit keep-list of item IDs;
    // clears everything else. The box save is serialized and pushed to
    // iCloud, so a 400-slot box inflates the save ~5x and uploads start
    // failing.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let keepWeapons: Set<Int32> = [82, 23, 47, 222, 242, 252]
    let keepItems: Set<Int32> = Set((args.count > 2 ? args[2] : "").split(separator: ",").compactMap { Int32($0) })
    let slots = gt.boxSlots(mem)
    if slots.isEmpty { print("box list empty — open the item box in-game"); break }
    var kept = 0, cleared = 0
    for s in slots where !s.isEmpty {
        // Keep every weapon: they are few, and a box full of bulk items is
        // what inflated the save ~5x and broke iCloud upload.
        if s.weaponId > 0 { kept += 1; continue }
        _ = keepWeapons
        if s.itemId > 0 && keepItems.contains(s.itemId) { kept += 1; continue }
        gt.clearSlot(mem, s); cleared += 1
    }
    print("kept \(kept), cleared \(cleared)")

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

case "ext":
    // Read-only survey of the extended TDB features. Safe first check: it
    // writes nothing, so it confirms every type resolves and every field reads
    // plausibly before anything is set.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    print("  resolved types:")
    for t in RE2Ext.allTypes.sorted() {
        if let r = gt.resolved(t, mem) {
            let n = gt.db.instances(mem, managedVT: r.vt).count
            print("    \(t)  vt=0x\(String(r.vt, radix:16)) base=0x\(String(r.base, radix:16))  \(n) live")
        } else {
            print("    \(t)  NOT RESOLVED")
        }
    }
    print("  ink ribbons  : \(gt.inkRibbons(mem).map { String($0.1) }.joined(separator: ", "))")
    print("  item slots   : \(gt.slotSize(mem).map { String($0.1) }.joined(separator: ", "))")
    print("  conditions   : \(gt.survivorConditions(mem).map { "0x" + String($0, radix: 16) }.joined(separator: ", "))")
    print("  recoil blocks: \(gt.gunParamBlocks(mem, field: RE2Ext.recoilParamField).count)")
    print("  sway blocks  : \(gt.gunParamBlocks(mem, field: RE2Ext.deviateParamField).count)")

case "stagger":
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let on = args.count > 2 ? (args[2] != "0") : true
    print("  IgnoreBlow \(on ? "ON" : "OFF") on \(gt.setIgnoreBlow(mem, on: on)) instance(s)")

case "grapple":
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let on = args.count > 2 ? (args[2] != "0") : true
    print("  IgnoreGrapple \(on ? "ON" : "OFF") on \(gt.setIgnoreGrapple(mem, on: on)) instance(s)")

case "ribbons":
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let n = args.count > 2 ? (Int32(args[2]) ?? 99) : 99
    print("  before: \(gt.inkRibbons(mem).map { String($0.1) })")
    print("  wrote \(gt.setInkRibbons(mem, to: n)) instance(s) = \(n)")

case "slots":
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let n = args.count > 2 ? (Int32(args[2]) ?? RE2Ext.maxSlotSize) : RE2Ext.maxSlotSize
    print("  before: \(gt.slotSize(mem).map { String($0.1) })")
    print("  wrote \(gt.setSlotSize(mem, to: n)) instance(s) = \(n)")

case "recoil":
    // recoil 1            -> zero Pitch/Yaw, printing the originals
    // recoil <pitch> <yaw> -> write those values back
    // The GUI toggle remembers originals itself; the CLI prints them so a
    // manual restore is possible without guessing.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    let blocks = gt.gunParamBlocks(mem, field: RE2Ext.recoilParamField)
    if blocks.isEmpty { fail("no gun equipped — no recoil block to edit") }
    if args.count > 3, let p = Float(args[2]), let y = Float(args[3]) {
        for b in blocks { gt.restoreRecoil(mem, block: b, pitch: p, yaw: y) }
        print("  restored Pitch=\(p) Yaw=\(y) on \(blocks.count) block(s)")
    } else {
        for b in blocks {
            if let o = gt.zeroRecoil(mem, block: b) {
                print("  0x\(String(b, radix: 16)) zeroed (was Pitch=\(o.pitch) Yaw=\(o.yaw))")
            } else {
                print("  0x\(String(b, radix: 16)) skipped — values not sane")
            }
        }
    }

case "gunparams":
    // Read-only dump of the parameter blocks a Gun points at, so their layout
    // can be checked against the TDB before anything is written.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    guard let g = gt.resolved(RE2Ext.gunType, mem) else { fail("Gun not resolved") }
    func f32(_ a: UInt64) -> Float { Float(bitPattern: mem.readU32(a) ?? 0) }
    for o in gt.db.instances(mem, managedVT: g.vt) {
        print("  Gun 0x\(String(o, radix: 16))")
        for (label, fld, names) in [
            ("RecoilParam", RE2Ext.recoilParamField,
             [("Curve", UInt64(0x00)), ("Pitch", 0x08), ("Yaw", 0x0c),
              ("CurveTime", 0x10), ("InputTime", 0x14), ("Time", 0x18)]),
            ("DeviateParam", RE2Ext.deviateParamField,
             [("TransX", UInt64(0x10)), ("TransY", 0x18), ("TransZ", 0x20),
              ("RotX", 0x28), ("RotY", 0x30), ("RotZ", 0x38), ("LifeTime", 0x40)]),
        ] {
            guard let blk = mem.readU64(o &+ g.base &+ fld), blk > 0x100000000 else {
                print("    \(label): null"); continue
            }
            let vt = mem.readU64(blk) ?? 0
            let base = UInt64(bitPattern: Int64(gt.db.fieldPtrOffset(mem, managedVT: vt)))
            print("    \(label) @0x\(String(blk, radix: 16)) vt=0x\(String(vt, radix: 16)) base=0x\(String(base, radix: 16))")
            for (n, off) in names {
                let a = blk &+ base &+ off
                print("      \(n) = \(f32(a))   (u32=\(mem.readU32(a) ?? 0))")
            }
        }
    }

case "setplaytime":
    // setplaytime HH:MM:SS — the shown clock is elapsed minus demo minus
    // pause, so only _GameElapsedTime is rewritten and the other three
    // accumulators are left exactly as the game maintains them.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    guard let r = gt.resolvedIndex(RE2Ext.gameSaveDataIndex, mem) else { fail("GameSaveData not resolved") }
    if SaveGuard.isSaving(mem) { fail("a save is in progress — try again in a moment") }
    let spec = args.count > 2 ? args[2] : "00:30:00"
    let parts = spec.split(separator: ":").compactMap { Int64($0) }
    guard parts.count == 3 else { fail("usage: setplaytime HH:MM:SS") }
    let targetUS = (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1_000_000

    var changed = 0
    for o in gt.db.instances(mem, managedVT: r.vt) {
        let ea = o &+ r.base &+ RE2Ext.elapsedTimeField
        guard let el = mem.readU64(ea), el > 0,
              let demo = mem.readU64(o &+ r.base &+ RE2Ext.demoTimeField),
              let pause = mem.readU64(o &+ r.base &+ RE2Ext.pauseTimeField)
        else { continue }
        // Only touch records whose arithmetic currently makes sense, so a
        // half-initialised container is never written to.
        let shown = Int64(bitPattern: el) - Int64(bitPattern: demo) - Int64(bitPattern: pause)
        guard shown > 0, shown < 400 * 3600 * 1_000_000 else { continue }
        let newElapsed = UInt64(targetUS) &+ demo &+ pause
        if mem.writeU64(ea, newElapsed) { changed += 1 }
    }
    print("  rewrote _GameElapsedTime on \(changed) record(s) -> \(spec)")
    for o in gt.db.instances(mem, managedVT: r.vt) {
        guard let el = mem.readU64(o &+ r.base &+ RE2Ext.elapsedTimeField), el > 0,
              let demo = mem.readU64(o &+ r.base &+ RE2Ext.demoTimeField),
              let pause = mem.readU64(o &+ r.base &+ RE2Ext.pauseTimeField) else { continue }
        let s = (Int64(bitPattern: el) - Int64(bitPattern: demo) - Int64(bitPattern: pause)) / 1_000_000
        print(String(format: "    0x%llx now shows %02d:%02d:%02d", o, s/3600, (s%3600)/60, s%60))
    }

case "playtime":
    // Reads all four GameSaveData time fields. Displayed playtime is believed
    // to be elapsed minus demo/inventory/pause, in microseconds; this prints
    // the arithmetic so it can be checked against the in-game clock.
    let mem = attach()
    guard let gt = GameTypes(mem) else { fail("type database not found") }
    guard let r = gt.resolvedIndex(RE2Ext.gameSaveDataIndex, mem) else { fail("GameSaveData not resolved") }
    func hms(_ us: Int64) -> String {
        let s = max(0, us) / 1_000_000
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    for o in gt.db.instances(mem, managedVT: r.vt) {
        let f = [0x08, 0x10, 0x18, 0x20].map { mem.readU64(o &+ r.base &+ UInt64($0)) ?? 0 }
        // Displayed playtime = elapsed - demo - pause. Inventory time counts
        // as play time and is NOT subtracted; including it gave 00:34:29 when
        // the game actually showed 01:27:36.
        let shown = Int64(bitPattern: f[0]) - Int64(bitPattern: f[1]) - Int64(bitPattern: f[3])
        print("  0x\(String(o, radix:16))  elapsed=\(f[0]) demo=\(f[1]) inv=\(f[2]) pause=\(f[3])")
        print("     raw=\(hms(Int64(bitPattern: f[0])))  shown=\(hms(shown))")
    }

default:
    print("""
    RE2Trainer — Resident Evil 2, macOS build \(GameProcess.expectedVersion)

    usage: sudo re2trainer <command>
      status    verify binary, report player/enemy/inventory state
      godmode   pin player health to maximum
      onehit    drop all enemies to 1 HP
      inv       list the player's inventory slots
      give      put the six infinite weapons into empty slots
      topup <w> <n>     set a weapon's ammo count
      ext       survey the extended TDB features (read-only)
      stagger <0|1>     IgnoreBlow  — player is not staggered by hits
      grapple <0|1>     IgnoreGrapple — enemies cannot grab the player
      ribbons <n>       set typewriter ink ribbons remaining
      slots <n>         set inventory slot count (max 20)
      playtime  decode the four GameSaveData time accumulators
      clearweapon <w>   remove a weapon from the inventory

    GUI: sudo .build/release/RE2TrainerGUI
    """)
}
