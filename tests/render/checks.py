"""Geometry diagnostics on the dumped scene (python3 tests/render/checks.py [--work DIR]).

Finds problems a preview image can hide:
  * floating parts: visible parts with no chain of contacts down to the terrain / snow skirt
    (contact = a surface sample point of one part inside another part, or at the ground),
  * buried parts: visible parts entirely under the TerrainModel surface,
  * clashes: visible parts of DIFFERENT top-level models pushed into each other,
  * camp footprint overlaps between tents, buildings and the spawn pad,
  * route steps: walked route segments whose terrain height leaves the route line.
Ground = TerrainModel.heightAt on the dumped 2-stud grid (what the builders place against).
"""
from __future__ import annotations

import argparse
import collections
import os
import sys

import numpy as np

sys.dont_write_bytecode = True  # keep tests/render free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render as R  # noqa: E402

TOL = 0.06  # contact tolerance in studs


def half_extents(s, i):
    k = R.part_kind(s, i)
    size = s.size[i]
    if k == "ball":
        return np.full(3, size.min() / 2), "ball"
    if k in ("cyl", "cyl_mesh"):
        d = min(size[1], size[2])
        return np.array([size[0], d, d]) / 2, "cyl"
    if k == "sphere_mesh":
        return size * s.ms[i] / 2, "ball"
    if k == "head":
        return np.full(3, size.min() * s.ms[i].min() / 2), "box"
    if k == "wedge":
        return size / 2, "wedge"
    return size / 2, "box"


def samples(kind):
    pts = []
    if kind == "ball":
        for a in range(3):
            for sgn in (-1, 1):
                p = [0, 0, 0]
                p[a] = sgn
                pts.append(p)
        for x in (-1, 1):
            for y in (-1, 1):
                for z in (-1, 1):
                    pts.append([x * .577, y * .577, z * .577])
    elif kind == "cyl":
        for x in (-1, 0, 1):
            for k in range(8):
                a = k * np.pi / 4
                pts.append([x, np.cos(a), np.sin(a)])
        pts += [[-1, 0, 0], [1, 0, 0]]
    else:
        for x in (-1, 0, 1):
            for y in (-1, 0, 1):
                for z in (-1, 0, 1):
                    if (x, y, z) != (0, 0, 0):
                        pts.append([x, y, z])
        if kind == "wedge":  # drop the corners that the slope cuts away (top front)
            pts = [p for p in pts if not (p[1] > 0 and p[2] < 0 and p[1] - p[2] > 1.01)]
    return np.array(pts, float)


SAMPLES = {k: samples(k) for k in ("box", "ball", "cyl", "wedge")}


def top_model(path, depth):
    parts = path.split("/")
    return "/".join(parts[:depth])


def model_key(path):
    """Top-level prop model a part belongs to (e.g. Mountain/Camps/BaseCamp/DomeTent#)."""
    p = path.split("/")
    if p[0] == "Mountain":
        if len(p) > 2 and p[1] == "Camps":
            return "/".join(p[:4])
        if len(p) > 2 and p[1] == "Route" and p[2] == "Markers":
            return "/".join(p[:4])
        return "/".join(p[:3])
    return p[0]


def run(s, out=print):
    n = s.n
    vis = s.transp < 0.95
    H = np.zeros((n, 3))
    kinds = []
    for i in range(n):
        h, k = half_extents(s, i)
        H[i] = h
        kinds.append(k)
    # World sample points and AABBs.
    pts = []
    lo = np.zeros((n, 3))
    hi = np.zeros((n, 3))
    for i in range(n):
        loc = SAMPLES[kinds[i]] * H[i]
        w = loc @ s.R[i].T + s.pos[i]
        pts.append(w)
        ext = np.abs(s.R[i]) @ H[i]
        lo[i], hi[i] = s.pos[i] - ext, s.pos[i] + ext
    huge = (hi - lo).max(1) > 300
    ground_part = np.array([("SnowSkirt" in p) for p in s.path])
    keys = [model_key(p) for p in s.path]

    # Model instance per part: the ancestor at the model's depth (ids from the dump).
    inst = []
    for i in range(n):
        depth = keys[i].count("/") + 1
        anc = s.anc[i]
        inst.append(f"{keys[i]}#{anc[min(depth, len(anc)) - 1]}")
    s.inst = inst
    def inside(i, P, tol):
        loc = (P - s.pos[i]) @ s.R[i]
        if kinds[i] == "ball":
            return ((loc / np.maximum(H[i] + tol, 1e-6)) ** 2).sum(1) <= 1
        if kinds[i] == "cyl":
            r = H[i][1] + tol
            return (np.abs(loc[:, 0]) <= H[i][0] + tol) & (loc[:, 1] ** 2 + loc[:, 2] ** 2 <= r * r)
        ok = (np.abs(loc) <= H[i] + tol).all(1)
        if kinds[i] == "wedge":
            # Below the slope plane through (y=+h, z=+h) and (y=-h, z=-h).
            hy, hz = H[i][1], H[i][2]
            ok &= (loc[:, 1] / max(hy, 1e-6) - loc[:, 2] / max(hz, 1e-6)) <= 1e-6 + tol * 2 / min(hy, hz)
        return ok

    # Spatial hash of the non-huge visible parts.
    cell = 8.0
    grid = collections.defaultdict(list)
    for i in np.nonzero(vis & ~huge)[0]:
        a = np.floor((lo[i] - TOL) / cell).astype(int)
        b = np.floor((hi[i] + TOL) / cell).astype(int)
        for x in range(a[0], b[0] + 1):
            for y in range(a[1], b[1] + 1):
                for z in range(a[2], b[2] + 1):
                    grid[(x, y, z)].append(i)
    neighbours = [set() for _ in range(n)]
    for lst in grid.values():
        if len(lst) > 1:
            for i in lst:
                neighbours[i].update(lst)
    for i in np.nonzero(vis & ~huge)[0]:
        neighbours[i].discard(i)
        for j in np.nonzero(vis & huge)[0]:
            if (lo[i] <= hi[j] + TOL).all() and (hi[i] >= lo[j] - TOL).all():
                neighbours[i].add(j)

    # Contacts and clashes.
    adj = [set() for _ in range(n)]
    clashes = collections.defaultdict(list)
    for i in np.nonzero(vis & ~huge)[0]:
        for j in neighbours[i]:
            if (lo[i] > hi[j] + TOL).any() or (hi[i] < lo[j] - TOL).any():
                continue
            if inside(j, pts[i], TOL).any() or inside(i, pts[j], TOL).any():
                adj[i].add(j)
                adj[j].add(i)
                if inst[i] != inst[j] and not huge[j] and inst[i] < inst[j]:
                    deep_i = inside(j, pts[i], -0.3).sum()
                    deep_j = inside(i, pts[j], -0.3).sum()
                    if deep_i + deep_j >= 3:
                        clashes[(inst[i], inst[j])].append((i, j))
    # Grounding: sample points at/below the terrain, or touching the skirt.
    grounded = np.zeros(n, bool)
    buried = np.zeros(n, bool)
    for i in np.nonzero(vis)[0]:
        if ground_part[i]:
            grounded[i] = True
            continue
        if huge[i]:
            grounded[i] = True  # backdrop peaks, skirt
            continue
        P = pts[i]
        g = R.ground(s, P[:, 0], P[:, 2])
        below = P[:, 1] <= g + 0.15
        if below.any():
            grounded[i] = True
        if (P[:, 1] < g - 0.05).all():
            buried[i] = True
    for i in np.nonzero(vis & huge & ~ground_part)[0]:
        pass
    # Flood fill from grounded parts.
    supported = grounded.copy()
    stack = list(np.nonzero(grounded & vis)[0])
    while stack:
        i = stack.pop()
        for j in adj[i]:
            if not supported[j] and vis[j]:
                supported[j] = True
                stack.append(j)
    floating = vis & ~supported
    # Characters: their feet are on the ground, so gear hangs off the body chain.
    report = collections.OrderedDict()
    byinst = collections.defaultdict(list)
    for i in np.nonzero(floating)[0]:
        byinst[inst[i]].append(i)
    out("== Floating parts (no contact chain down to the ground)")
    if not byinst:
        out("  none")
    grouped = collections.defaultdict(list)
    for k, idx in byinst.items():
        grouped[k.split("#")[0]].append((k, idx))
    def gap_to_support(i):
        """Smallest distance from part i's samples to a supported part's box, or to the ground."""
        P = pts[i]
        best, who = np.inf, "ground"
        g = R.ground(s, P[:, 0], P[:, 2])
        best = float((P[:, 1] - g).min())
        cand = np.nonzero(vis & supported & ~huge & (lo <= P.max(0) + 3).all(1) & (hi >= P.min(0) - 3).all(1))[0]
        for j in cand:
            loc = (P - s.pos[j]) @ s.R[j]
            d = np.linalg.norm(np.maximum(np.abs(loc) - H[j], 0), axis=1).min()
            if d < best:
                best, who = float(d), s.path[j].split("/")[-1]
        return best, who

    for k, lst in sorted(grouped.items()):
        total = sum(len(idx) for _, idx in lst)
        k0, idx0 = lst[0]
        names = collections.Counter(s.path[i].split("/")[-1] for i in idx0)
        i = idx0[0]
        g = float(R.ground(s, s.pos[i][0], s.pos[i][2]))
        gap, who = min(gap_to_support(j) for j in idx0)
        out(f"  {k}: {total} parts in {len(lst)} instance(s); e.g. {k0} parts {dict(names.most_common(4))} "
            f"at ({s.pos[i][0]:.1f}, {s.pos[i][1]:.1f}, {s.pos[i][2]:.1f}), ground {g:.1f}; "
            f"closest support: {who} {gap:.2f} studs away")
    report["floating"] = byinst
    out("== Buried parts (entirely under the terrain surface)")
    bb = collections.Counter(keys[i].split("#")[0] for i in np.nonzero(buried)[0])
    if not bb:
        out("  none")
    for k, c in bb.most_common():
        ex = [i for i in np.nonzero(buried)[0] if keys[i] == k][0]
        out(f"  {k}: {c} parts, e.g. {s.path[ex]} at ({s.pos[ex][0]:.1f}, {s.pos[ex][1]:.1f}, {s.pos[ex][2]:.1f})")
    out("== Clashes between different models (parts pushed >0.3 studs into each other)")
    if not clashes:
        out("  none")
    for (a, b), pairs in sorted(clashes.items()):
        i, j = pairs[0]
        out(f"  {a} <-> {b}: {len(pairs)} part pairs, e.g. {s.path[i].split('/')[-1]} / "
            f"{s.path[j].split('/')[-1]} near ({s.pos[i][0]:.1f}, {s.pos[i][1]:.1f}, {s.pos[i][2]:.1f})")
    return floating, buried, clashes


def camp_overlaps(s, out=print):
    """Collidable footprints of camp children (tents, buildings, spawn, crates...) that overlap."""
    out("== Camp layout: collidable parts of different camp props overlapping (AABB, > 0.3 studs)")
    boxes = collections.defaultdict(lambda: [np.full(3, np.inf), np.full(3, -np.inf)])
    for i in range(s.n):
        p = s.path[i].split("/")
        if len(p) < 4 or p[1] != "Camps" or not s.collide[i] or s.transp[i] >= 0.95:
            continue
        if p[3] in ("Plinth",):
            continue
        k = s.inst[i]
        ext = np.abs(s.R[i]) @ (s.size[i] / 2)
        b = boxes[k]
        b[0] = np.minimum(b[0], s.pos[i] - ext)
        b[1] = np.maximum(b[1], s.pos[i] + ext)
    names = sorted(boxes)
    found = False
    for a in range(len(names)):
        for b in range(a + 1, len(names)):
            A, B = names[a], names[b]
            if A.split("/")[2] != B.split("/")[2]:
                continue
            la, ha = boxes[A]
            lb, hb = boxes[B]
            ov = np.minimum(ha, hb) - np.maximum(la, lb)
            inside = ((la >= lb - 0.01) & (ha <= hb + 0.01)).all() or ((lb >= la - 0.01) & (hb <= ha + 0.01)).all()
            if (ov[[0, 2]] > 0.3).all() and ov[1] > 0 and not inside:
                found = True
                out(f"  {A} [{la[0]:.1f}..{ha[0]:.1f} x {la[2]:.1f}..{ha[2]:.1f}] overlaps {B} "
                    f"[{lb[0]:.1f}..{hb[0]:.1f} x {lb[2]:.1f}..{hb[2]:.1f}] by {ov[0]:.1f} x {ov[2]:.1f} studs")
    if not found:
        out("  none")


def route_steps(s, out=print):
    out("== Route: walked segments whose terrain leaves the route line by > 2 studs")
    found = False
    for name in sorted(set(r[0] for r in s.route)):
        pts = [r for r in s.route if r[0] == name]
        for a, b in zip(pts[:-1], pts[1:]):
            if b[5] != "Walk":
                continue
            t = np.linspace(0, 1, 60)
            x = a[2] + (b[2] - a[2]) * t
            y = a[3] + (b[3] - a[3]) * t
            z = a[4] + (b[4] - a[4]) * t
            g = R.ground(s, x, z)
            d = g - y
            k = int(np.argmax(np.abs(d)))
            if abs(d[k]) > 2:
                found = True
                out(f"  {name} {a[6]}#{a[1]} -> {b[6]}#{b[1]}: terrain {d[k]:+.1f} studs vs route at "
                    f"({x[k]:.0f}, {y[k]:.0f}, {z[k]:.0f})")
    if not found:
        out("  none")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "game-render"))
    ap.add_argument("--no-dump", action="store_true")
    args = ap.parse_args()
    path = os.path.join(args.work, "scene.tsv")
    if not args.no_dump or not os.path.exists(path):
        path = R.run_dump(args.work)
    s = R.load_scene(path)
    for w in s.warns:
        print("WARN:", w)
    run(s)
    camp_overlaps(s)
    route_steps(s)


if __name__ == "__main__":
    main()
