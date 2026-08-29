# RE2Trainer

A pointer-chain trainer for the **macOS (Mac App Store) build of Resident Evil 2 (2019)**,
written in Swift. As far as I can tell this is the first trainer targeting this build —
every existing RE2 trainer is Windows-only, and GitHub has no code referencing the
`jp.co.capcom.RE2US` bundle identifier.

## Why this build is trainable

The App Store binary is signed **without the hardened runtime** (`codesign` reports
`flags=0x0`). On macOS, `task_for_pid` is denied for hardened-runtime targets even to
root, but this binary is only sandboxed and notarized — so root can obtain a task port
with SIP left fully enabled. No SIP disabling, no code injection, no patching the app
bundle (which would break its App Store signature).

## How it works

It reads the game's own **type database**.

RE Engine ships a TDB — a table of every type in the game, with names — and
every managed object begins with a pointer to its type. So the trainer does not
infer what an object is; it looks it up:

```
find TDB (magic "TDB\0", v74, 102,046 types)
  -> resolve "app.ropeway.HitPointController"      (player health)
  -> resolve "app.ropeway.EnemyHitPointController" (enemy health)
  -> enumerate instances by their type pointer
     health fields at +0x50: marker(1), max, current
```

Player and enemy health are **different declared types**, so telling them apart
needs no heuristic at all.

TDB structure layout comes from [REFramework](https://github.com/praydog/REFramework)
(`shared/sdk/RETypeDB.hpp`, `RETypeDefinition.hpp`). REFramework injects a DLL
and is Windows-only; none of that is needed here, because the TDB is plain data
readable through `task_for_pid`. This is not a port — it uses their
reverse-engineering of the format as a specification.

### Why not signature scanning

Earlier versions identified objects by struct shape: "marker==1, max==1200 is
the player." Measured against the type database on the same running game:

| | type database | signature scan |
|---|---|---|
| player | 1200/1200, **1 instance** | 0/1200, **37 candidates** |
| enemies | 4 alive, HP 560/770/830/890 | 31 "alive", all assumed 620 |

The heuristic reported the player's health as `0/1200` and produced 37
candidates, 36 of them wrong — and writing to all 37 froze the game. It also
hard-coded enemy HP at 620, silently missing every enemy with different HP,
which in one room was all of them.

### Everything is a name lookup

The TDB carries field names too, so features are found rather than hunted:

```
findfield SaveCount   -> GameHeaderSaveData +0x50 SaveTimes
findfield Wince       -> EnemyAddDamageController +0x54 WinceRange
findfield DownTime    -> DownTimeInfo +0x04 DownTime
```

Measured against the scanning approaches they replaced:

| target | by scanning | by name |
|---|---|---|
| player health | 37 candidates, HP misread as 0/1200 | 1 instance, exact |
| enemy health | assumed all 620 HP | own type; real HP 530-890 |
| game timer | five approaches, all failed | one named boolean |
| save counter | 178,360 candidates, then a segfault | one lookup |
| item box | ~15 copies, edits vanished | one list, edits persist |

The save counter is the sharpest example. Scanning narrowed 178,360 candidates
to 13 across three save cycles; four were `(index, -1)` handle pairs, writing
to them crashed the game, and the result was never confirmed. `findfield
SaveCount` returned the type, field and offset directly.

### Engine flags beat write loops

The engine exposes its own switches, found by reading field names:

```
app.ropeway.HitPointController
  +0x01  <Invincible>k__BackingField
  +0x02  <NoDamage>k__BackingField

app.ropeway.GameClock
  +0x29  _MeasureGameElapsedTime     clear to stop the in-game timer

GameHeaderSaveData
  +0x50  SaveTimes                   zero it; the next save records 1
```

Mr. X (`em7100`) is put on his knees by forcing his
`EnemyHitPointController` current HP to 0, and stays there while it is held.
He is told apart from ordinary enemies by max HP: zombies observed at 530-890,
him at 1100. The engine calls the stagger a "wince"
(`<CurrentWincePoint>`, `WinceRange`), and
`app.ropeway.enemy.em7100.Accessor_Em7100` names the state directly with
`b_KneelDown` / `_KneelDown` — useful if the HP route ever stops working.

The save counter is incremented by the game on save, so writing `1` directly is
overwritten. Writing `0` lets the game's own increment produce `1` — a value it
computed itself, and therefore one it serialises happily.

These are *set*, not pinned. Nothing races the engine, nothing fights a save,
and there is no loop to crash. The in-game timer stopped dead at 01:27:35 the
moment the flag was cleared, after five different value-scanning approaches had
failed to even locate it.

### There is no infinite-ammo flag

Searched the entire type database and string pool: no `Infinite`, `Unlimited`,
`Endless` or `NoConsume` name exists anywhere. RE2's six bonus weapons are
infinite because the game's *code* special-cases those weapon IDs, not because
of a data field. Any other weapon can only be topped up by writing `Count`,
which is what the Infinite Magnum toggle does.

Setting `Count = -1` (the value some infinite weapons appeared to hold) does not
work — it displays as `-1` and decrements normally.

### Inventory and the item box

```
carried:  InventoryManager -> CurrentInventory -> _Slots -> Slot._Stock -> DefaultItem
box:      ItemBoxBehavior.<ItemList>  (400 slots, exists only while the box is open)
PrimitiveItem:  ItemId, WeaponId, WeaponParts, BulletId, Count
```

Every hop is a named field, which reaches the single authoritative slot list.
Signature scanning found ~15 parallel copies of the inventory with no way to
tell which the game actually read — the reason earlier item edits kept
appearing and then vanishing on reload.

### Why not pointer chains

An earlier version shipped 43 static chains verified to survive one game
restart. On the next restart, all 61 candidates failed. One successful restart
is not proof.

## Version safety

Offsets are only valid for the exact binary they were derived from. The trainer verifies
the code signature's CDHash on startup and warns loudly on a mismatch:

```
bundle    jp.co.capcom.RE2US
version   1.0.2 (build 25022100.0)
arch      arm64
cdhash    adcde5dbe9400fc7f81e6a3762591504a871644f
```

## Usage

### GUI (menu bar app)

```sh
./make_app.sh
sudo ./RE2Trainer.app/Contents/MacOS/RE2Trainer
```

A menu-bar icon with switches for Godmode, One-Hit Kill and Infinite Magnum.
It attaches automatically and re-attaches when the game restarts.

### CLI

```sh
swift build -c release
sudo .build/release/re2trainer status     # read-only: player, enemies, inventory
sudo .build/release/re2trainer godmode    # pin player health
sudo .build/release/re2trainer onehit     # drop enemies to 1 HP
```

Root is required for `task_for_pid`. `status` is read-only and is the right first thing
to run.

## Scope

Single-player only. Resident Evil 2 has no competitive multiplayer; this reads and writes
the memory of a game running on your own machine.

## Status

- [x] Godmode (signature-based)
- [x] One-hit kill (signature-based, zombie confirmed)
- [x] Infinite magnum (signature-based, item vtable derived at runtime)
- [x] GUI with toggles
- [ ] More enemy types — each needs its max HP confirmed by diffing a kill
- [ ] Save counter — three addresses found; the game increments on save, so
      zeroing it makes the next save write 1. Not yet wired into the trainer.
- [ ] Game timer freeze — unsolved. Value scanning in every encoding (int,
      float, double, frames, centi/deci/milliseconds) failed; the displayed
      time appears to be computed at render time rather than stored.

### Inventory notes (for future work)

Item entries are 0x30 bytes:

```
+0x00   vtable (heap pointer; low bits 0xa26058 stable across sessions)
+0x10   Item ID     (-1/0 when the entry is a weapon)
+0x14   Weapon ID   (-1 when the entry is an item)
+0x18   Upgrades
+0x1c   Ammo Type   (e.g. 0x0F = Handgun Ammo)
+0x20   Quantity
```

Slots are stored as a main entry plus a companion at `+0x30`, with slots `0x150` apart.
The inventory list exists as multiple parallel copies; only one drives the UI, and
writing to the others has no visible effect — identifying the live copy by matching
on-screen contents is the reliable approach.

Infinite-ammo weapon IDs: Samurai Edge 82, LE 5 23, Combat Knife 47, ATM-4 222,
Anti-tank Rocket 242, Minigun 252. There is no infinite Lightning Hawk (magnum).
