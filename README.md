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

Heap addresses change every launch, so the trainer ships **static pointer chains**
instead:

```
moduleBase + 0xb158138  ->  +0x480  ->  +0x98  ->  +0x390   =  health component
```

`moduleBase` is read at runtime via `proc_regionfilename`, which accounts for ASLR.
Each chain is dereferenced in turn and validated against the known struct shape before
use, so a stale chain is skipped rather than trusted.

**43 chains** are bundled for the health component. All of them were verified to survive
a full game restart — a fresh launch rebases the module *and* reallocates the heap, and
18 of the original 61 candidates died at that step. Only survivors ship. The trainer
walks them shortest-first and accepts the first that resolves to a valid component,
so no single chain is a point of failure.

### Health component layout

```
+0x00   marker    always 1
+0x04   max HP    1200 (player)
+0x08   current HP
```

Max HP of 1200 is player-specific, which is what distinguishes the player's component
from enemy health objects.

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

```sh
swift build -c release
sudo .build/release/RE2Trainer status     # verify + resolve, changes nothing
sudo .build/release/RE2Trainer godmode    # pin health to maximum
```

Root is required for `task_for_pid`. `status` is read-only and is the right first thing
to run.

## Scope

Single-player only. Resident Evil 2 has no competitive multiplayer; this reads and writes
the memory of a game running on your own machine.

## Status

- [x] Health (43 verified chains)
- [ ] Ammo / inventory — item structs are located and understood, chains not yet scanned
- [ ] Save counter — candidates narrowed but not confirmed

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
