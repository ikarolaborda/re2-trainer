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

Everything is **signature-based**: features find their targets by struct *shape*,
not by address or offset.

```
health component:   +0x00 marker(1)   +0x04 max HP   +0x08 current HP
item entry:         +0x10 itemID  +0x14 weaponID  +0x18 upgrades
                    +0x1c ammoType  +0x20 quantity
```

The player is identified by `max == 1200`, which no enemy shares. Enemies are
matched against an allow-list of confirmed max-HP values (zombie = 620).

### Why not pointer chains

The first version of this trainer shipped 43 static pointer chains
(`moduleBase + offset -> +off -> +off`) to the player's health component. They
were built from a scan of 61 candidates, of which 43 resolved correctly through
a full game restart — ASLR rebase and heap reallocation included.

**On the next restart, all 61 failed.** Not one resolved.

So the "verified" set was a sample of one, and a chain that survives a restart
once is not a chain that survives restarts. Struct shapes, by contrast, have
held across every session observed. Signature scanning is also strictly more
portable: it needs no module base, so it is immune to ASLR, and it survives
game patches that would invalidate every offset.

The chains are preserved in git history if anyone wants to revisit them.

### Enemy detection is an allow-list, deliberately

A generic "any health-shaped struct that isn't the player" signature matches
**~86,000** locations in a live game, nearly all of them ordinary data. Writing
to those would be reckless — an earlier version of this work crashed the game
by writing to unverified candidates. Only confirmed enemy types are targeted;
`Scanner.knownEnemyMaxHP` documents how to add more (snapshot, damage one
enemy, diff for what decreased).

### Cost

A full scan reads ~3.5 GB. Loops therefore cache their targets and re-scan every
5 seconds, writing to the cached set at ~8 Hz in between. An early version
scanned at tick frequency and pushed the game to 384% CPU.

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
