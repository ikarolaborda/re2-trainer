#!/usr/bin/env python3
"""Offline RE Engine TDB explorer.

The TDB is embedded in the game's Mach-O at a fixed offset, with all internal
pointers stored relative to the TDB base. That makes the entire type database
readable from disk, so type/field research needs no running game and no
task_for_pid. Layout matches Sources/RE2TrainerCore/TypeDB.swift exactly.
"""
import mmap, struct, sys, os, json, re

BIN = "/Applications/Resident Evil 2.app/Contents/MacOS/Resident Evil 2"
BASE = 0x8da47c8
TYPEDEF_SZ, TYPEIMPL_SZ, FIELDIMPL_SZ = 0x50, 0x30, 0x0c

f = open(BIN, "rb")
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

def u32(o): return struct.unpack_from("<I", m, BASE + o)[0]
def u64(o): return struct.unpack_from("<Q", m, BASE + o)[0]
def cstr(o, cap=256):
    p = BASE + o
    e = m.find(b"\0", p, p + cap)
    return m[p:e].decode("utf-8", "replace") if e > 0 else ""

VERSION, NUMTYPES = u32(4), u32(8)
TYPES, TYPESIMPL, STRPOOL = u64(0x68), u64(0x70), u64(0xd8)
FIELDSARR, FIELDSIMPL = u64(0x88), u64(0x90)

def type_name(i):
    td = TYPES + i * TYPEDEF_SZ
    w1 = struct.unpack_from("<Q", m, BASE + td + 8)[0]
    ti = TYPESIMPL + ((w1 >> 38) & 0x3FFFF) * TYPEIMPL_SZ
    w = struct.unpack_from("<Q", m, BASE + ti)[0]
    nm = cstr(STRPOOL + (w & 0x0FFFFFFF))
    ns = cstr(STRPOOL + ((w >> 32) & 0x0FFFFFFF))
    if not nm: return None
    return f"{ns}.{nm}" if ns else nm

def fields(i):
    td = TYPES + i * TYPEDEF_SZ
    w1 = struct.unpack_from("<Q", m, BASE + td + 8)[0]
    w2 = struct.unpack_from("<Q", m, BASE + td + 0x20)[0]
    ti = TYPESIMPL + ((w1 >> 38) & 0x3FFFF) * TYPEIMPL_SZ
    w3 = struct.unpack_from("<Q", m, BASE + ti + 0x10)[0]
    n = (w3 >> 33) & 0xFFFFFF
    mf = (w2 >> 44) & 0xFFFFF
    if not (0 < n < 4096): return []
    out = []
    for j in range(n):
        fw = struct.unpack_from("<Q", m, BASE + FIELDSARR + (mf + j) * 8)[0]
        fi = FIELDSIMPL + ((fw >> 19) & 0x7FFFF) * FIELDIMPL_SZ
        off = struct.unpack_from("<I", m, BASE + fi + 4)[0] & 0x03FFFFFF
        no  = struct.unpack_from("<I", m, BASE + fi + 8)[0] & 0x0FFFFFFF
        nm = cstr(STRPOOL + no)
        if nm: out.append((nm, off))
    return out

CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tdb_names.json")
def all_names():
    if os.path.exists(CACHE):
        return json.load(open(CACHE))
    names = {}
    for i in range(NUMTYPES):
        try:
            n = type_name(i)
        except Exception:
            continue
        if n: names[str(i)] = n
    json.dump(names, open(CACHE, "w"))
    return names

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "info"
    if cmd == "info":
        print(f"TDB v{VERSION} types={NUMTYPES}")
    elif cmd == "search":                      # search <regex> [limit]
        rx = re.compile(sys.argv[2], re.I)
        lim = int(sys.argv[3]) if len(sys.argv) > 3 else 60
        n = 0
        for i, nm in all_names().items():
            if rx.search(nm):
                print(f"[{i}] {nm}"); n += 1
                if n >= lim: break
    elif cmd == "fields":                      # fields <index|exactname>
        a = sys.argv[2]
        if a.isdigit(): idx = int(a)
        else:
            idx = next((int(i) for i, nm in all_names().items() if nm == a), None)
            if idx is None: print("no such type"); sys.exit(1)
        print(f"[{idx}] {type_name(idx)}")
        for nm, off in fields(idx):
            print(f"  +0x{off:03x}  {nm}")
    elif cmd == "grepfield":                   # grepfield <regex> [limit]
        rx = re.compile(sys.argv[2], re.I)
        lim = int(sys.argv[3]) if len(sys.argv) > 3 else 40
        n = 0
        for i, nm in all_names().items():
            try: fl = fields(int(i))
            except Exception: continue
            hit = [(a, b) for a, b in fl if rx.search(a)]
            if hit:
                print(f"[{i}] {nm}")
                for a, b in hit: print(f"    +0x{b:03x}  {a}")
                n += 1
                if n >= lim: break

def dump_all(path):
    """Full type+field dump, one line per field: idx<TAB>type<TAB>+off<TAB>field"""
    names = all_names()
    with open(path, "w") as fh:
        for i, nm in names.items():
            try: fl = fields(int(i))
            except Exception: continue
            for a, b in fl:
                fh.write(f"{i}\t{nm}\t0x{b:03x}\t{a}\n")
