"""Voxel-style terrain mesh for the preview renderer.

Roblox terrain is a voxel volume: WorldBuilder replays TerrainModel.ops with FillBlock /
FillBall / FillCylinder (solid), Air fills (carves) and ReplaceMaterial. A heightfield cannot
show what that produces where a fill overhangs (a dome whose widest point is above the
ground), so this module rebuilds the volume the same way: a signed distance field composed
in op order (Fill = union, Carve = subtraction), sampled on Roblox's 4-stud voxel grid and
meshed with surface nets (a smooth isosurface, like Roblox's smooth terrain). Each triangle's
material comes from replaying the ops at a point just inside the surface (Fill sets the
material, Carve sets Air, Replace swaps source -> target), so Snow / Glacier / Rock appear
exactly where the fills put them.
"""
from __future__ import annotations

import hashlib
import os

import numpy as np

VOXEL = 4.0
CHUNK = 32  # cells per chunk side (128 studs)
MAT_CODES = {"Snow": 0, "Glacier": 1, "Rock": 2, "Slate": 3, "Air": 4, "Ice": 5}


class Op:
    __slots__ = ("name", "shape", "mode", "material", "source", "c", "axes", "half", "radius", "height", "lo", "hi")


def parse_ops(rows):
    ops = []
    for r in rows:
        o = Op()
        o.name, o.shape, o.mode, o.material, o.source = r[:5]
        v = np.array([float(t) for t in r[5:]])
        o.c = v[0:3]
        o.axes = v[3:12].reshape(3, 3)  # rows: right, up, back
        o.half = v[12:15] / 2
        o.radius, o.height = v[15], v[16]
        if o.shape == "Box":
            ext = np.abs(o.axes).T @ o.half
        elif o.shape == "Ball":
            ext = np.array([o.radius] * 3)
        else:
            ext = np.array([o.radius, o.height / 2, o.radius])
        o.lo, o.hi = o.c - ext, o.c + ext
        ops.append(o)
    return ops


def op_sdf(o: Op, P):
    d = P - o.c
    if o.shape == "Box":
        q = np.abs(d @ o.axes.T) - o.half
        out = np.linalg.norm(np.maximum(q, 0), axis=1)
        return out + np.minimum(q.max(1), 0)
    if o.shape == "Ball":
        return np.linalg.norm(d, axis=1) - o.radius
    qx = np.hypot(d[:, 0], d[:, 2]) - o.radius
    qy = np.abs(d[:, 1]) - o.height / 2
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0)


def op_inside(o: Op, P):
    d = P - o.c
    if o.shape == "Box":
        return (np.abs(d @ o.axes.T) <= o.half + 1e-6).all(1)
    if o.shape == "Ball":
        return (d * d).sum(1) <= o.radius * o.radius
    return (d[:, 0] ** 2 + d[:, 2] ** 2 <= o.radius ** 2) & (np.abs(d[:, 1]) <= o.height / 2)


def material_at(ops, P):
    """Voxel material at points, replaying the ops in order (Air where nothing is solid)."""
    mat = np.full(len(P), MAT_CODES["Air"], np.int8)
    if len(P) == 0:
        return mat
    lo, hi = P.min(0), P.max(0)
    for o in ops:
        if (o.hi < lo).any() or (o.lo > hi).any():
            continue
        m = ((P >= o.lo) & (P <= o.hi)).all(1)
        if not m.any():
            continue
        idx = np.nonzero(m)[0]
        idx = idx[op_inside(o, P[idx])]
        if len(idx) == 0:
            continue
        if o.mode == "Fill":
            mat[idx] = MAT_CODES.get(o.material, 0)
        elif o.mode == "Carve":
            mat[idx] = MAT_CODES["Air"]
        else:
            sel = idx[mat[idx] == MAT_CODES.get(o.source, -1)]
            mat[sel] = MAT_CODES.get(o.material, 0)
    return mat


def _chunk_field(ops, xs, ys, zs):
    X, Y, Z = np.meshgrid(xs, ys, zs, indexing="ij")
    P = np.stack([X.ravel(), Y.ravel(), Z.ravel()], 1)
    d = np.full(len(P), 8.0)
    lo = np.array([xs[0], ys[0], zs[0]])
    hi = np.array([xs[-1], ys[-1], zs[-1]])
    for o in ops:
        if (o.hi < lo - 8).any() or (o.lo > hi + 8).any():
            continue
        m = ((P >= o.lo - 8) & (P <= o.hi + 8)).all(1)
        if not m.any():
            continue
        idx = np.nonzero(m)[0]
        sd = op_sdf(o, P[idx])
        if o.mode == "Fill":
            d[idx] = np.minimum(d[idx], sd)
        elif o.mode == "Carve":
            d[idx] = np.maximum(d[idx], -sd)
    return np.clip(d, -8, 8).reshape(len(xs), len(ys), len(zs))


def _surface_nets(f, xs, ys, zs, core):
    """Quads for sign-changing grid edges whose min corner lies in `core` (x/z index ranges)."""
    nx, ny, nz = f.shape
    inside = f < 0
    # Cell vertices: mean of edge crossings.
    c = [f[i:nx - 1 + i, j:ny - 1 + j, k:nz - 1 + k] for i in (0, 1) for j in (0, 1) for k in (0, 1)]
    ins = [v < 0 for v in c]
    anyin = np.zeros_like(ins[0])
    allin = np.ones_like(ins[0])
    for v in ins:
        anyin |= v
        allin &= v
    active = anyin & ~allin
    ai = np.nonzero(active)
    corner = [(i, j, k) for i in (0, 1) for j in (0, 1) for k in (0, 1)]
    edges = [(a, b) for a in range(8) for b in range(a + 1, 8)
             if sum(abs(corner[a][t] - corner[b][t]) for t in range(3)) == 1]
    acc = np.zeros((len(ai[0]), 3))
    cnt = np.zeros(len(ai[0]))
    vals = [v[ai] for v in c]
    for a, b in edges:
        fa, fb = vals[a], vals[b]
        m = (fa < 0) != (fb < 0)
        t = np.where(m, fa / np.where(fa - fb == 0, 1, fa - fb), 0)
        pa = np.array(corner[a], float)
        pb = np.array(corner[b], float)
        acc += m[:, None] * (pa + (pb - pa) * t[:, None])
        cnt += m
    local = acc / np.maximum(cnt, 1)[:, None]
    step = VOXEL
    verts = np.stack([xs[0] + (ai[0] + local[:, 0]) * step, ys[0] + (ai[1] + local[:, 1]) * step,
                      zs[0] + (ai[2] + local[:, 2]) * step], 1)
    vid = np.full(active.shape, -1, np.int64)
    vid[ai] = np.arange(len(verts))
    quads = []
    out_dirs = []
    x0, x1, z0, z1 = core
    for axis in range(3):
        sl0 = [slice(None)] * 3
        sl1 = [slice(None)] * 3
        sl0[axis] = slice(0, -1)
        sl1[axis] = slice(1, None)
        a, b = inside[tuple(sl0)], inside[tuple(sl1)]
        e = np.nonzero(a != b)
        i, j, k = e
        # Owner filter on x/z.
        own = (i >= x0) & (i < x1) & (k >= z0) & (k < z1)
        i, j, k = i[own], j[own], k[own]
        flip = a[i, j, k]  # inside at the low end -> outward normal points along +axis
        others = [t for t in range(3) if t != axis]
        idx = [i, j, k]
        # The four cells around the edge.
        cells = []
        for du, dv in ((0, 0), (1, 0), (1, 1), (0, 1)):
            cidx = list(idx)
            cidx[others[0]] = cidx[others[0]] - du
            cidx[others[1]] = cidx[others[1]] - dv
            cells.append(cidx)
        ok = np.ones(len(i), bool)
        for cidx in cells:
            for t in range(3):
                ok &= (cidx[t] >= 0) & (cidx[t] < active.shape[t])
        ids = []
        for cidx in cells:
            ids.append(vid[tuple(np.clip(cidx[t][ok], 0, active.shape[t] - 1) for t in range(3))])
        q = np.stack(ids, 1)
        good = (q >= 0).all(1)
        q = q[good]
        fl = flip[ok][good]
        d = np.zeros((len(q), 3))
        d[:, axis] = np.where(fl, 1.0, -1.0)
        quads.append(q)
        out_dirs.append(d)
    if not quads:
        return verts, np.zeros((0, 4), np.int64), np.zeros((0, 3))
    return verts, np.concatenate(quads), np.concatenate(out_dirs)


def build_mesh(op_rows, bounds, log=print):
    """Whole-terrain mesh: tris (T,3,3), normals (T,3), vertex normals (T,3,3), vertex materials (T,3)."""
    ops = parse_ops(op_rows)
    x0, z0, x1, z1 = bounds
    gx = np.arange(np.floor(x0 / VOXEL) * VOXEL, x1 + VOXEL, VOXEL)
    gz = np.arange(np.floor(z0 / VOXEL) * VOXEL, z1 + VOXEL, VOXEL)
    all_v, all_t, all_d, all_c = [], [], [], []
    base = 0
    for ci in range(0, len(gx) - 1, CHUNK):
        for cj in range(0, len(gz) - 1, CHUNK):
            i0, i1 = max(ci - 1, 0), min(ci + CHUNK + 2, len(gx))
            j0, j1 = max(cj - 1, 0), min(cj + CHUNK + 2, len(gz))
            xs, zs = gx[i0:i1], gz[j0:j1]
            sel = [o for o in ops if o.mode != "Replace" and o.hi[0] >= xs[0] - 8 and o.lo[0] <= xs[-1] + 8
                   and o.hi[2] >= zs[0] - 8 and o.lo[2] <= zs[-1] + 8]
            if not sel:
                continue
            ylo = min(o.lo[1] for o in sel)
            yhi = max(o.hi[1] for o in sel)
            ys = np.arange(np.floor(ylo / VOXEL) * VOXEL - 2 * VOXEL, yhi + 3 * VOXEL, VOXEL)
            f = _chunk_field(sel, xs, ys, zs)
            core = (ci - i0, min(ci + CHUNK, len(gx) - 1) - i0, cj - j0, min(cj + CHUNK, len(gz) - 1) - j0)
            v, q, d = _surface_nets(f, xs, ys, zs, core)
            if len(q) == 0:
                continue
            all_v.append(v)
            all_t.append(q + base)
            all_d.append(d)
            base += len(v)
    V = np.concatenate(all_v)
    Q = np.concatenate(all_t)
    D = np.concatenate(all_d)
    # Two triangles per quad, wound so the normal points out of the solid.
    T = np.concatenate([Q[:, [0, 1, 2]], Q[:, [0, 2, 3]]])
    Dt = np.concatenate([D, D])
    tri = V[T]
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    nn = np.linalg.norm(n, axis=1)
    good = nn > 1e-9
    T, Dt, n, nn = T[good], Dt[good], n[good], nn[good]
    n = n / nn[:, None]
    flip = (n * Dt).sum(1) < 0
    n[flip] *= -1
    T[flip] = T[flip][:, [0, 2, 1]]
    # Smooth vertex normals (area weighted), like Roblox's smooth terrain shading.
    vn = np.zeros_like(V)
    for k in range(3):
        np.add.at(vn, T[:, k], n)
    vn /= np.maximum(np.linalg.norm(vn, axis=1, keepdims=True), 1e-9)
    tri = V[T]
    # Material per vertex: replay the ops just inside the surface. The renderer blends the
    # three vertex materials across each triangle, like Roblox blending voxel materials.
    vm = np.full(len(V), MAT_CODES["Air"], np.int8)
    for depth in (1.5, 0.75, 3.0, 5.0):
        need = vm == MAT_CODES["Air"]
        if not need.any():
            break
        vm[need] = material_at(ops, V[need] - vn[need] * depth)
    vm[vm == MAT_CODES["Air"]] = MAT_CODES["Snow"]
    log(f"  terrain mesh: {len(V)} vertices, {len(T)} triangles")
    return tri.astype(np.float32), n.astype(np.float32), vn[T].astype(np.float32), vm[T]


def cached_mesh(op_rows, bounds, work, log=print):
    h = hashlib.sha1(repr((op_rows, bounds, VOXEL, CHUNK, 4)).encode()).hexdigest()[:16]
    path = os.path.join(work, f"terrain-{h}.npz")
    if os.path.exists(path):
        z = np.load(path)
        return z["tri"], z["n"], z["vn"], z["mat"]
    tri, n, vn, mat = build_mesh(op_rows, bounds, log)
    np.savez(path, tri=tri, n=n, vn=vn, mat=mat)
    return tri, n, vn, mat
