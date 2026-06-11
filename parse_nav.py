#!/usr/bin/env python3
# Parse CS:GO de_mirage.nav -> walkbot graph JSON via resync scanning.
# We reliably read each area's HEADER (id, corners, 4 connection lists),
# then resync to the next area header by signature, skipping the fragile
# variable-length tail (hiding spots / encounter paths / vis).
import struct, json, sys

PATH = "/projects/sandbox/lua1/de_mirage.nav"
OUT  = "/projects/sandbox/lua1/mirage_nav.json"
data = open(PATH, "rb").read()
N = len(data)

def u32(o):  return struct.unpack_from("<I", data, o)[0]
def f32(o):  return struct.unpack_from("<f", data, o)[0]

# ---- header ----
off = 0
assert u32(0) == 0xFEEDFACE
off = 9  # magic(4)+ver(4)+? we re-read properly below
off = 0
off += 4  # magic
ver = u32(off); off += 4
sub = u32(off); off += 4
off += 4  # bsp size
off += 1  # analyzed
pc = struct.unpack_from("<H", data, off)[0]; off += 2
for _ in range(pc):
    ln = struct.unpack_from("<H", data, off)[0]; off += 2 + ln
off += 1  # has unnamed
area_count = u32(off); off += 4
print("ver", ver, "sub", sub, "areas", area_count, "data_start", off, file=sys.stderr)

# map coordinate sanity bounds (Mirage-ish, generous)
def valid_coord(x, y, z):
    return -6000 < x < 6000 and -6000 < y < 6000 and -1000 < z < 1500

def try_header(o):
    """Return (aid, cx, cy, cz, tgts, after_off) if a valid area header is at o."""
    if o + 40 > N: return None
    aid  = u32(o)
    if aid == 0 or aid > 200000: return None
    nwx, nwy, nwz = f32(o+8), f32(o+12), f32(o+16)
    sex, sey, sez = f32(o+20), f32(o+24), f32(o+28)
    if not (valid_coord(nwx, nwy, nwz) and valid_coord(sex, sey, sez)):
        return None
    p = o + 40  # past id, attr, 6 corner floats, 2 z floats
    tgts = []
    for d in range(4):
        if p + 4 > N: return None
        cc = u32(p); p += 4
        if cc > 64: return None
        for _ in range(cc):
            if p + 4 > N: return None
            tgts.append(u32(p)); p += 4
    cx = (nwx + sex) / 2.0
    cy = (nwy + sey) / 2.0
    cz = (nwz + sez) / 2.0
    return aid, cx, cy, cz, tgts, p

nodes = []
id_to_idx = {}
conns = []
o = off
found = 0
while found < area_count and o < N:
    hdr = try_header(o)
    if hdr is None:
        o += 1
        continue
    aid, cx, cy, cz, tgts, after = hdr
    if aid in id_to_idx:
        # duplicate id at a false-positive offset -> skip ahead
        o += 1
        continue
    idx = len(nodes)
    id_to_idx[aid] = idx
    nodes.append({"x": round(cx,1), "y": round(cy,1), "z": round(cz,1)})
    conns.append((aid, tgts))
    found += 1
    # resync: scan forward from 'after' for the next valid header
    no = after
    limit = min(N, after + 20000)
    while no < limit:
        if try_header(no) is not None:
            break
        no += 1
    o = no

print("found areas:", found, file=sys.stderr)

edges = {}
for aid, tgts in conns:
    fi = id_to_idx.get(aid)
    if fi is None: continue
    for t in tgts:
        ti = id_to_idx.get(t)
        if ti is None: continue
        edges.setdefault(fi, [])
        if ti not in edges[fi]: edges[fi].append(ti)
        edges.setdefault(ti, [])
        if fi not in edges[ti]: edges[ti].append(fi)

edges_out = {str(k+1): [x+1 for x in v] for k, v in edges.items()}
out = {"nodes": nodes, "edges": edges_out}
json.dump(out, open(OUT, "w"))
tot_e = sum(len(v) for v in edges_out.values())
print("WROTE", OUT, "nodes:", len(nodes), "edge_keys:", len(edges_out), "edge_refs:", tot_e, file=sys.stderr)
