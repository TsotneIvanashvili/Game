#!/usr/bin/env python3
"""Approximate preview renderer for the generated world (NOT Roblox's renderer).

    python3 tests/render/render.py                 # dump the scene, render every preset
    python3 tests/render/render.py camp1 summit    # only these presets
    python3 tests/render/render.py --list          # list presets
    python3 tests/render/render.py --check         # print geometry diagnostics only

Pipeline: `luaurun tests/render/dump.luau <repo>` runs the real WorldBuilder / CampKit /
RouteKit / AssetFactory / GearFactory / EquipmentService code in a headless mock and prints
every part, the terrain heightfield (from TerrainModel, 2-stud grid) and the terrain op list.
This script rasterises that with a numpy z-buffer: flat-shaded triangles, a directional sun
with a shadow map, sky-tinted ambient light, material tints, distance fog, a sky gradient,
2x2 supersampling, and SurfaceGui / BillboardGui text drawn onto the right parts.

Dependencies: Python 3, numpy, Pillow. Outputs go to docs/previews/ by default.
"""
from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.dont_write_bytecode = True  # keep tests/render free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import terrain  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

MAT_CODES = {"S": 0, "G": 1, "R": 2, "L": 3, "A": 4, "I": 5}
MAT_NAMES = ["Snow", "Glacier", "Rock", "Slate", "Air", "Ice"]
# Terrain material colours exactly as WorldBuilder sets them (Terrain:SetMaterialColor).
TERRAIN_COLORS = np.array(
    [[236, 242, 250], [92, 205, 214], [104, 104, 112], [92, 92, 100], [236, 242, 250], [150, 210, 235]],
    np.float32,
) / 255.0


def unit(v):
    v = np.asarray(v, np.float64)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.where(n == 0, 1, n)


# ------------------------------------------------------------------------------------------
# Scene loading
# ------------------------------------------------------------------------------------------
class Scene:
    pass


def run_dump(work: str) -> str:
    os.makedirs(work, exist_ok=True)
    path = os.path.join(work, "scene.tsv")
    t = time.time()
    with open(path, "w") as f:
        subprocess.run(["luaurun", os.path.join(HERE, "dump.luau"), REPO], stdout=f, check=True, cwd=REPO)
    print(f"dump: {path} ({time.time() - t:.1f}s)")
    return path


def load_scene(path: str) -> Scene:
    s = Scene()
    P = []
    s.texts, s.ops, s.camps, s.route, s.chars, s.logs, s.warns = [], [], [], [], {}, [], []
    s.lights = []
    rows = {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        k = f[0]
        if k == "P":
            P.append(f)
        elif k == "TR":
            rows[int(f[1])] = (f[2], f[3], f[4] if len(f) > 4 else f[3])
        elif k == "GRID":
            s.gx0, s.gz0, s.gstep, s.gnx, s.gnz = float(f[1]), float(f[2]), float(f[3]), int(f[4]), int(f[5])
        elif k == "TXT":
            s.texts.append(f[1:])
        elif k == "OP":
            s.ops.append(f[1:])
        elif k == "CAMP":
            s.camps.append((f[1], f[2], float(f[3]), float(f[4]), float(f[5]), float(f[6])))
        elif k == "ROUTE":
            s.route.append((f[1], int(f[2]), float(f[3]), float(f[4]), float(f[5]), f[6], f[7]))
        elif k == "CHAR":
            s.chars[f[1]] = (float(f[2]), float(f[3]), float(f[4]), float(f[5]))
        elif k == "LIGHT":
            s.lights.append((f[1], int(f[2]), float(f[3]), float(f[4]), float(f[5]), float(f[6]), float(f[7])))
        elif k == "LOG":
            s.logs.append(f[1])
        elif k == "WARN":
            s.warns.append(f[1])
    n = len(P)
    s.n = n
    s.pid = np.array([int(f[1]) for f in P])
    s.path = [f[2] for f in P]
    s.cls = np.array([f[3] for f in P])
    s.shape = np.array([f[4] for f in P])
    s.mesh = np.array([f[5] for f in P])
    num = np.array([[float(x) for x in f[6:30]] for f in P], np.float64)
    s.ms, s.mo, s.size, s.pos = num[:, 0:3], num[:, 3:6], num[:, 6:9], num[:, 9:12]
    s.R = num[:, 12:21].reshape(n, 3, 3).transpose(0, 2, 1)  # columns: right, up, back
    s.color = num[:, 21:24].astype(np.float32)
    s.transp = np.array([float(f[30]) for f in P])
    s.material = np.array([f[31] for f in P])
    s.shadow = np.array([f[32] == "true" for f in P])
    s.collide = np.array([f[33] == "true" for f in P])
    s.anc = [f[34].split(".") for f in P]
    s.index_of = {int(f[1]): i for i, f in enumerate(P)}
    H = np.zeros((s.gnz, s.gnx), np.float32)
    M = np.zeros((s.gnz, s.gnx), np.uint8)
    B = np.zeros((s.gnz, s.gnx), np.uint8)
    for iz in range(s.gnz):
        hs, ms, bs = rows[iz]
        H[iz] = np.array(hs.split(","), np.float32)
        M[iz] = np.frombuffer(ms.encode(), np.uint8)
        B[iz] = np.frombuffer(bs.encode(), np.uint8)
    lut = np.full(256, 4, np.int8)
    for c, v in MAT_CODES.items():
        lut[ord(c)] = v
    s.H, s.M, s.B = H, lut[M], lut[B]
    return s


def ground(s: Scene, x, z):
    """Bilinear terrain height from the dumped grid (TerrainModel.heightAt at 2-stud spacing)."""
    fx = (np.asarray(x, np.float64) - s.gx0) / s.gstep
    fz = (np.asarray(z, np.float64) - s.gz0) / s.gstep
    ix = np.clip(np.floor(fx).astype(int), 0, s.gnx - 2)
    iz = np.clip(np.floor(fz).astype(int), 0, s.gnz - 2)
    tx, tz = np.clip(fx - ix, 0, 1), np.clip(fz - iz, 0, 1)
    h = s.H
    return (h[iz, ix] * (1 - tx) * (1 - tz) + h[iz, ix + 1] * tx * (1 - tz)
            + h[iz + 1, ix] * (1 - tx) * tz + h[iz + 1, ix + 1] * tx * tz)


# ------------------------------------------------------------------------------------------
# Unit meshes (outward winding fixed against the shape's own centroid; all are convex)
# ------------------------------------------------------------------------------------------
def fix_winding(V, T):
    V = np.asarray(V, np.float64)
    T = np.array(T, np.int64)
    c = V.mean(0)
    n = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    flip = (n * (V[T].mean(1) - c)).sum(1) < 0
    T[flip] = T[flip][:, [0, 2, 1]]
    return V, T


def quads(qs):
    out = []
    for a, b, c, d in qs:
        out += [(a, b, c), (a, c, d)]
    return out


def box_mesh():
    V = [[x, y, z] for x in (-.5, .5) for y in (-.5, .5) for z in (-.5, .5)]
    i = lambda x, y, z: x * 4 + y * 2 + z  # noqa: E731
    Q = [(i(0, 0, 0), i(0, 1, 0), i(0, 1, 1), i(0, 0, 1)), (i(1, 0, 0), i(1, 0, 1), i(1, 1, 1), i(1, 1, 0)),
         (i(0, 0, 0), i(0, 0, 1), i(1, 0, 1), i(1, 0, 0)), (i(0, 1, 0), i(1, 1, 0), i(1, 1, 1), i(0, 1, 1)),
         (i(0, 0, 0), i(1, 0, 0), i(1, 1, 0), i(0, 1, 0)), (i(0, 0, 1), i(0, 1, 1), i(1, 1, 1), i(1, 0, 1))]
    return fix_winding(V, quads(Q))


def wedge_mesh():
    # Roblox WedgePart: full bottom and back (+Z) faces, slope from the top back edge down to
    # the bottom front (-Z) edge.
    V = [[-.5, -.5, -.5], [.5, -.5, -.5], [.5, -.5, .5], [-.5, -.5, .5], [-.5, .5, .5], [.5, .5, .5]]
    T = quads([(0, 1, 2, 3), (3, 2, 5, 4), (0, 4, 5, 1)]) + [(0, 3, 4), (1, 5, 2)]
    return fix_winding(V, T)


def cornerwedge_mesh():
    # Square base, apex above the (+X, -Z) corner.
    V = [[-.5, -.5, -.5], [.5, -.5, -.5], [.5, -.5, .5], [-.5, -.5, .5], [.5, .5, -.5]]
    T = quads([(0, 1, 2, 3)]) + [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)]
    return fix_winding(V, T)


def cylinder_mesh(n=20):
    V, T = [], []
    for s in (-.5, .5):
        for j in range(n):
            a = 2 * math.pi * j / n
            V.append([s, .5 * math.cos(a), .5 * math.sin(a)])
    V += [[-.5, 0, 0], [.5, 0, 0]]
    for j in range(n):
        a, b = j, (j + 1) % n
        T += [(a, b, n + b), (a, n + b, n + a), (2 * n, b, a), (2 * n + 1, n + a, n + b)]
    return fix_winding(V, T)


def revolve(profile, n=20):
    """Surface of revolution about Y from (radius, y) pairs, top to bottom, closed at the ends."""
    V, T = [], []
    for r, y in profile:
        for j in range(n):
            a = 2 * math.pi * j / n
            V.append([r * math.cos(a), y, r * math.sin(a)])
    for i in range(len(profile) - 1):
        for j in range(n):
            a, b = i * n + j, i * n + (j + 1) % n
            T += [(a, b, b + n), (a, b + n, a + n)]
    top, bot = len(V), len(V) + 1
    V += [[0, profile[0][1], 0], [0, profile[-1][1], 0]]
    last = (len(profile) - 1) * n
    for j in range(n):
        T += [(top, (j + 1) % n, j), (bot, last + j, last + (j + 1) % n)]
    return fix_winding(V, T)


def sphere_mesh(rings=10, n=20):
    prof = [(0.5 * math.sin(math.pi * i / rings), 0.5 * math.cos(math.pi * i / rings)) for i in range(1, rings)]
    return revolve(prof, n)


def head_mesh():
    # Classic Roblox head: a rounded cylinder.
    prof = [(0.36, 0.5), (0.44, 0.47), (0.49, 0.38), (0.5, 0.25), (0.5, -0.25), (0.49, -0.38), (0.44, -0.47),
            (0.36, -0.5)]
    return revolve(prof, 20)


MESHES = {
    "box": box_mesh(), "wedge": wedge_mesh(), "cornerwedge": cornerwedge_mesh(), "cyl": cylinder_mesh(),
    "sphere": sphere_mesh(), "head": head_mesh(),
}


def truss_boxes(size):
    """TrussPart lattice in local space: 4 corner rails and rungs every 2 studs on each side."""
    axis = int(np.argmax(size))
    o = [i for i in range(3) if i != axis]
    L = size[axis]
    w = 0.3
    boxes = []
    for a in (-1, 1):
        for b in (-1, 1):
            c = np.zeros(3)
            c[o[0]] = a * (size[o[0]] / 2 - w / 2)
            c[o[1]] = b * (size[o[1]] / 2 - w / 2)
            s = np.zeros(3)
            s[axis], s[o[0]], s[o[1]] = L, w, w
            boxes.append((c, s))
    k = 0
    while k * 2 + 1 <= L:
        t = -L / 2 + 1 + k * 2
        for side in range(4):
            c = np.zeros(3)
            s = np.zeros(3)
            c[axis] = t
            s[axis] = 0.22
            along, across = (o[0], o[1]) if side < 2 else (o[1], o[0])
            c[across] = (1 if side % 2 else -1) * (size[across] / 2 - w / 2)
            s[across], s[along] = 0.22, size[along]
            boxes.append((c, s))
        k += 1
    return boxes


def part_kind(s: Scene, i: int) -> str:
    if s.cls[i] == "TrussPart":
        return "truss"
    m = s.mesh[i]
    if m == "Sphere":
        return "sphere_mesh"
    if m == "Head":
        return "head"
    if m == "Brick":
        return "brick_mesh"
    if m == "Cylinder":
        return "cyl_mesh"
    if s.cls[i] == "WedgePart":
        return "wedge"
    if s.cls[i] == "CornerWedgePart":
        return "cornerwedge"
    if s.shape[i] == "Cylinder":
        return "cyl"
    if s.shape[i] == "Ball":
        return "ball"
    if s.shape[i] == "Wedge":
        return "wedge"
    if s.shape[i] == "CornerWedge":
        return "cornerwedge"
    return "box"


def build_part_tris(s: Scene, select):
    """World triangles for the selected parts: (tris (T,3,3), normals (T,3), part index (T,))."""
    kinds = {}
    for i in np.nonzero(select)[0]:
        kinds.setdefault(part_kind(s, i), []).append(i)
    tris, owner = [], []
    for kind, idx in kinds.items():
        idx = np.array(idx)
        size, ms, mo = s.size[idx], s.ms[idx], s.mo[idx]
        offset = np.zeros_like(size)
        if kind == "truss":
            for i in idx:
                for c, sz in truss_boxes(s.size[i]):
                    V, T = MESHES["box"]
                    loc = V * sz + c
                    w = loc @ s.R[i].T + s.pos[i]
                    tris.append(w[T])
                    owner.append(np.full(len(T), i))
            continue
        if kind in ("box", "brick_mesh"):
            mesh, scale = "box", size * (ms if kind == "brick_mesh" else 1)
        elif kind == "wedge":
            mesh, scale = "wedge", size
        elif kind == "cornerwedge":
            mesh, scale = "cornerwedge", size
        elif kind in ("cyl", "cyl_mesh"):
            d = np.minimum(size[:, 1], size[:, 2])
            mesh, scale = "cyl", np.stack([size[:, 0], d, d], 1)
        elif kind == "ball":
            d = size.min(1)
            mesh, scale = "sphere", np.stack([d, d, d], 1)
        elif kind == "sphere_mesh":
            mesh, scale = "sphere", size * ms
        else:  # head
            d = size.min(1)[:, None]
            mesh, scale = "head", d * ms
        if kind in ("sphere_mesh", "head", "brick_mesh", "cyl_mesh"):
            offset = mo
        V, T = MESHES[mesh]
        loc = V[None] * scale[:, None] + offset[:, None]
        w = np.einsum("nij,nvj->nvi", s.R[idx], loc) + s.pos[idx][:, None]
        tris.append(w[:, T].reshape(-1, 3, 3))
        owner.append(np.repeat(idx, len(T)))
    if not tris:
        return np.zeros((0, 3, 3)), np.zeros((0, 3)), np.zeros(0, int)
    tris = np.concatenate(tris)
    owner = np.concatenate(owner)
    n = unit(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]))
    good = np.isfinite(n).all(1) & (np.abs(n).sum(1) > 0)
    return tris[good], n[good], owner[good]


# ------------------------------------------------------------------------------------------
# Cameras
# ------------------------------------------------------------------------------------------
class Camera:
    def __init__(self, pos, target, W, H, fov=70.0, ortho=None, up=(0, 1, 0), near=0.1, lod=None):
        self.pos = np.array(pos, np.float64)
        self.f = unit(np.array(target, np.float64) - self.pos)
        upv = np.array(up, np.float64)
        if abs(self.f @ unit(upv)) > 0.999:
            upv = np.array([0, 0, 1.0])
        self.r = unit(np.cross(self.f, upv))
        self.u = np.cross(self.r, self.f)
        self.W, self.H = W, H
        self.ortho = ortho  # half-height of the view in studs, or None for perspective
        self.fov = fov
        self.F = (H / 2) / math.tan(math.radians(fov) / 2)
        self.near = near
        self.lod = lod or [(150, 2), (400, 4), (900, 8), (2000, 16), (1e9, 32)]

    def terrain_lod(self, d):
        for limit, step in self.lod:
            if d <= limit:
                return step
        return self.lod[-1][1]

    def distance(self, p):
        return float(np.linalg.norm(np.asarray(p) - self.pos))

    def to_cam(self, P):
        d = P - self.pos
        return np.stack([d @ self.r, d @ self.u, d @ self.f], -1)

    def sphere_visible(self, c, radius):
        q = self.to_cam(np.asarray(c, np.float64)[None])[0]
        if self.ortho:
            hw = self.ortho * self.W / self.H
            return abs(q[0]) <= hw + radius and abs(q[1]) <= self.ortho + radius
        if q[2] < -radius:
            return False
        tx = (self.W / 2) / self.F
        ty = (self.H / 2) / self.F
        # Plane distances for the four side planes.
        for t, comp in ((tx, q[0]), (ty, q[1])):
            k = 1 / math.sqrt(1 + t * t)
            if (abs(comp) - t * q[2]) * k > radius:
                return False
        return True

    def project(self, Pc):
        """Camera-space points -> pixel x, y and the z-test key (smaller is nearer)."""
        if self.ortho:
            s = (self.H / 2) / self.ortho
            return self.W / 2 + Pc[..., 0] * s, self.H / 2 - Pc[..., 1] * s, Pc[..., 2]
        z = Pc[..., 2]
        return self.W / 2 + Pc[..., 0] / z * self.F, self.H / 2 - Pc[..., 1] / z * self.F, -1.0 / z

    def pixel_rays(self):
        ys, xs = np.mgrid[0:self.H, 0:self.W]
        xn = (xs + 0.5 - self.W / 2) / self.F
        yn = -(ys + 0.5 - self.H / 2) / self.F
        return xn, yn

    def world_from_key(self, key):
        """World positions of every pixel from the z-buffer keys."""
        ys, xs = np.mgrid[0:self.H, 0:self.W]
        if self.ortho:
            s = self.ortho / (self.H / 2)
            xc = (xs + 0.5 - self.W / 2) * s
            yc = -(ys + 0.5 - self.H / 2) * s
            zc = key
        else:
            zc = -1.0 / np.where(key < 0, key, -1e-9)
            xc = (xs + 0.5 - self.W / 2) / self.F * zc
            yc = -(ys + 0.5 - self.H / 2) / self.F * zc
        return self.pos + xc[..., None] * self.r + yc[..., None] * self.u + zc[..., None] * self.f, zc


def clip_near(Pc, near, src):
    """Clip camera-space triangles against z = near. Returns triangles and their source ids."""
    ins = Pc[:, :, 2] >= near
    cnt = ins.sum(1)
    out, ids = [Pc[cnt == 3]], [src[cnt == 3]]
    for want in (1, 2):
        m = cnt == want
        if not m.any():
            continue
        A, I, S = Pc[m], ins[m], src[m]
        key = I if want == 1 else ~I  # the lone vertex
        k = np.argmax(key, 1)
        order = (k[:, None] + np.arange(3)[None]) % 3
        A = np.take_along_axis(A, order[:, :, None], 1)
        a, b, c = A[:, 0], A[:, 1], A[:, 2]
        tb = ((near - a[:, 2]) / (b[:, 2] - a[:, 2]))[:, None]
        tc = ((near - a[:, 2]) / (c[:, 2] - a[:, 2]))[:, None]
        ab, ac = a + (b - a) * tb, a + (c - a) * tc
        if want == 1:
            out.append(np.stack([a, ab, ac], 1))
            ids.append(S)
        else:
            out.append(np.stack([ab, b, c], 1))
            out.append(np.stack([ab, c, ac], 1))
            ids += [S, S]
    return np.concatenate(out), np.concatenate(ids)


# ------------------------------------------------------------------------------------------
# Rasteriser: vectorised z-buffer over tiles of candidate pixels
# ------------------------------------------------------------------------------------------
def raster(xs, ys, keys, ids, W, H, zbuf=None, idbuf=None, budget=4_000_000):
    """xs, ys, keys: (T,3) pixel coords and z-test keys (smaller is nearer; linear in screen
    space). Writes the nearest triangle id per pixel; pixel centres sit at +0.5."""
    if zbuf is None:
        zbuf = np.full(W * H, np.inf, np.float64)
        idbuf = np.full(W * H, -1, np.int64)
    x0 = np.maximum(np.ceil(xs.min(1) - 0.5), 0)
    x1 = np.minimum(np.floor(xs.max(1) - 0.5), W - 1)
    y0 = np.maximum(np.ceil(ys.min(1) - 0.5), 0)
    y1 = np.minimum(np.floor(ys.max(1) - 0.5), H - 1)
    area = (xs[:, 1] - xs[:, 0]) * (ys[:, 2] - ys[:, 0]) - (xs[:, 2] - xs[:, 0]) * (ys[:, 1] - ys[:, 0])
    ok = (x1 >= x0) & (y1 >= y0) & (np.abs(area) > 1e-12) & np.isfinite(area)
    xs, ys, keys, ids, area = xs[ok], ys[ok], keys[ok], ids[ok], area[ok]
    x0, x1, y0, y1 = (v[ok].astype(np.int64) for v in (x0, x1, y0, y1))
    # Edge equations e_k(x, y) = A_k x + B_k y + C_k, normalised so inside is >= 0 and the
    # three sum to 1 (they are the barycentric weights).
    inv = 1.0 / area
    A = np.stack([ys[:, 1] - ys[:, 2], ys[:, 2] - ys[:, 0], ys[:, 0] - ys[:, 1]], 1) * inv[:, None]
    B = np.stack([xs[:, 2] - xs[:, 1], xs[:, 0] - xs[:, 2], xs[:, 1] - xs[:, 0]], 1) * inv[:, None]
    C = np.stack([xs[:, 1] * ys[:, 2] - xs[:, 2] * ys[:, 1], xs[:, 2] * ys[:, 0] - xs[:, 0] * ys[:, 2],
                  xs[:, 0] * ys[:, 1] - xs[:, 1] * ys[:, 0]], 1) * inv[:, None]
    kmin, kmax = float(keys.min()) if len(keys) else 0.0, float(keys.max()) if len(keys) else 1.0
    kscale = (2**31 - 2) / max(kmax - kmin, 1e-12)  # depth quantised for the per-chunk sort
    # Depth plane: key(x, y) = Ka x + Kb y + Kc.
    Ka = (A * keys).sum(1)
    Kb = (B * keys).sum(1)
    Kc = (C * keys).sum(1)
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    m = np.maximum(bw, bh)
    prev = 0
    for K in (1, 2, 4, 8, 16, 32):
        sel = ((m > prev) & (m <= K)) if K < 32 else (m > prev)
        prev = K
        if not sel.any():
            continue
        t = np.nonzero(sel)[0]
        ntx, nty = -(-bw[t] // K), -(-bh[t] // K)
        nt = ntx * nty
        tri = np.repeat(t, nt)
        start = np.repeat(np.cumsum(nt) - nt, nt)
        local = np.arange(len(tri)) - start
        rntx = np.repeat(ntx, nt)
        ox = x0[tri] + (local % rntx) * K
        oy = y0[tri] + (local // rntx) * K
        dy, dx = np.divmod(np.arange(K * K, dtype=np.int64), K)
        dxf, dyf = dx.astype(np.float32), dy.astype(np.float32)
        per = max(1, budget // (K * K))
        for c0 in range(0, len(tri), per):
            tt = tri[c0:c0 + per]
            cx = (ox[c0:c0 + per] + 0.5).astype(np.float64)
            cy = (oy[c0:c0 + per] + 0.5).astype(np.float64)
            # Values at the tile origin pixel centre, then per-pixel increments (float32).
            base = (A[tt] * cx[:, None] + B[tt] * cy[:, None] + C[tt]).astype(np.float32)
            a32, b32 = A[tt].astype(np.float32), B[tt].astype(np.float32)
            eps = np.float32(-1e-7)
            inside = np.ones((len(tt), K * K), bool)
            for k in range(3):
                e = base[:, k, None] + a32[:, k, None] * dxf + b32[:, k, None] * dyf
                inside &= e >= eps
            px = ox[c0:c0 + per, None] + dx
            py = oy[c0:c0 + per, None] + dy
            inside &= (px <= x1[tt, None]) & (py <= y1[tt, None])
            r, cidx = np.nonzero(inside)
            if len(r) == 0:
                continue
            ttr = tt[r]
            fx = (px[r, cidx] + 0.5)
            fy = (py[r, cidx] + 0.5)
            kk = Ka[ttr] * fx + Kb[ttr] * fy + Kc[ttr]
            pix = py[r, cidx] * W + px[r, cidx]
            better = kk < zbuf[pix]
            if not better.all():
                pix, kk, ttr = pix[better], kk[better], ttr[better]
            q = np.clip((kk - kmin) * kscale, 0, 2**31 - 1).astype(np.int64)
            order = np.argsort((pix << 31) | q)
            pix, kk, ttr = pix[order], kk[order], ttr[order]
            first = np.ones(len(pix), bool)
            first[1:] = pix[1:] != pix[:-1]
            pix, kk, ttr = pix[first], kk[first], ttr[first]
            zbuf[pix] = kk
            idbuf[pix] = ids[ttr]
    return zbuf, idbuf


# ------------------------------------------------------------------------------------------
# Materials, noise, terrain wall materials
# ------------------------------------------------------------------------------------------
def hash3(ix, iy, iz):
    h = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    h = h ^ (h >> 16)
    return (h & 0xFFFF).astype(np.float32) / 65535.0


def value_noise(p, scale):
    q = p / scale
    i = np.floor(q).astype(np.int64)
    f = q - i
    f = f * f * (3 - 2 * f)
    out = 0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (
                    f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * hash3(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz)
    return out


def grid_material(s: Scene, x, z):
    ix = np.clip(np.round((x - s.gx0) / s.gstep).astype(int), 0, s.gnx - 1)
    iz = np.clip(np.round((z - s.gz0) / s.gstep).astype(int), 0, s.gnz - 1)
    return s.M[iz, ix]


def terrain_albedo(s: Scene, P, n, mats):
    col = TERRAIN_COLORS[np.clip(mats, 0, 5)].copy()
    nz1 = value_noise(P, 9.0)
    nz2 = value_noise(P * [1, 4, 1], 6.0)
    snow = mats == 0
    col[snow] *= (0.97 + 0.04 * nz1[snow])[:, None]
    ice = mats == 1
    if ice.any():
        # Glacier: teal with darker bands and pale streaks running down the face.
        band = value_noise(P[ice] * [1, 0.25, 1], 7.0)
        dark = 0.78 + 0.22 * band
        c = col[ice] * dark[:, None]
        streak = np.clip((nz2[ice] - 0.62) * 2.2, 0, 1) * 0.45
        col[ice] = c + (np.array([0.93, 0.97, 1.0]) - c) * streak[:, None]
    rock = (mats == 2) | (mats == 3)
    col[rock] *= (0.85 + 0.25 * nz1[rock])[:, None]
    return col


PART_TINT = {"Snow": 1.0, "Fabric": 0.96, "WoodPlanks": 0.97, "Wood": 0.95, "Metal": 1.0}


# ------------------------------------------------------------------------------------------
# Text (SurfaceGui / BillboardGui)
# ------------------------------------------------------------------------------------------
FONT_PATHS = ["/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf", "/usr/share/fonts/opentype/inter/Inter-Bold.otf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]


def font(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            return ImageFont.truetype(p, max(4, int(size)))
    return ImageFont.load_default()


def fit_text(text, w, h, stroke=0):
    lo, hi = 4, 400
    while lo < hi:
        mid = (lo + hi + 1) // 2
        f = font(mid)
        b = f.getbbox(text, stroke_width=int(mid * stroke))
        if b[2] - b[0] <= w and b[3] - b[1] <= h:
            lo = mid
        else:
            hi = mid - 1
    return font(lo), lo


FACE_AXES = {  # face -> (normal axis, sign, text-right local axis, sign)
    "Front": (2, -1, 0, -1), "Back": (2, 1, 0, 1), "Right": (0, 1, 2, -1), "Left": (0, -1, 2, 1),
}


def perspective_coeffs(dst, src):
    """PIL PERSPECTIVE coefficients mapping output pixels (dst quad) to input pixels (src)."""
    A, B = [], []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        B += [u, v]
    return np.linalg.solve(np.array(A, np.float64), np.array(B, np.float64))


def draw_texts(s: Scene, cam: Camera, img, owner_pix, zc, ss):
    W, H = cam.W, cam.H
    for t in s.texts:
        kind, pid = t[0], int(t[1])
        i = s.index_of.get(pid)
        if i is None:
            continue
        rgb = tuple(int(float(c) * 255) for c in t[4:7])
        text = t[3]
        if kind == "surface":
            if t[2] not in FACE_AXES:
                continue
            na, nsgn, ra, rsgn = FACE_AXES[t[2]]
            size, R, pos = s.size[i], s.R[i], s.pos[i]
            nvec, rvec, uvec = R[:, na] * nsgn, R[:, ra] * rsgn, R[:, 1]
            if na == 1:
                continue
            fw, fh = size[ra], size[1]
            centre = pos + nvec * (size[na] / 2)
            # TextLabel: 92% x 78% of the face, centred.
            corners = [centre - rvec * fw * .46 + uvec * fh * .39, centre + rvec * fw * .46 + uvec * fh * .39,
                       centre + rvec * fw * .46 - uvec * fh * .39, centre - rvec * fw * .46 - uvec * fh * .39]
            if ((cam.pos - centre) @ nvec) <= 0:
                continue  # facing away
            Pc = cam.to_cam(np.array(corners))
            if not cam.ortho and (Pc[:, 2] < cam.near).any():
                continue
            px, py, _ = cam.project(Pc)
            if px.max() < 0 or px.min() > W or py.max() < 0 or py.min() > H:
                continue
            span = max(np.hypot(px[1] - px[0], py[1] - py[0]), 1)
            quad = 0.5 * abs((px[2] - px[0]) * (py[3] - py[1]) - (px[3] - px[1]) * (py[2] - py[0]))
            if span < 6 or quad < 20:
                continue  # too small or seen edge-on
            tw = int(min(2048, max(64, fw * 40)))
            th = max(16, int(tw * fh * .78 / (fw * .92)))
            tex = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
            f, _ = fit_text(text, tw * 0.98, th * 0.9)
            d = ImageDraw.Draw(tex)
            b = d.textbbox((0, 0), text, font=f)
            d.text(((tw - (b[2] - b[0])) / 2 - b[0], (th - (b[3] - b[1])) / 2 - b[1]), text, font=f, fill=rgb + (255,))
            x0, y0 = int(max(0, np.floor(px.min()))), int(max(0, np.floor(py.min())))
            x1, y1 = int(min(W, np.ceil(px.max()) + 1)), int(min(H, np.ceil(py.max()) + 1))
            if x1 <= x0 or y1 <= y0:
                continue
            dst = [(px[k] - x0, py[k] - y0) for k in range(4)]
            src = [(0, 0), (tw, 0), (tw, th), (0, th)]
            try:
                coeffs = perspective_coeffs(dst, src)
            except np.linalg.LinAlgError:
                continue
            warped = tex.transform((x1 - x0, y1 - y0), Image.PERSPECTIVE, tuple(coeffs), Image.BILINEAR)
            a = np.asarray(warped, np.float32) / 255.0
            mask = (owner_pix[y0:y1, x0:x1] == i)
            alpha = a[..., 3] * mask
            reg = img[y0:y1, x0:x1]
            reg[:] = reg * (1 - alpha[..., None]) + a[..., :3] * alpha[..., None]
        else:
            off = np.array([float(v) for v in t[2].split(",")])
            sw, sh = float(t[7]), float(t[8])
            stroke = tuple(int(float(c) * 255) for c in t[9:12])
            centre = s.pos[i] + off
            Pc = cam.to_cam(centre[None])[0]
            if not cam.ortho and Pc[2] < 1:
                continue
            dist = cam.distance(centre)
            if dist > 900:
                continue
            px, py, _ = cam.project(Pc[None])
            scale = (cam.H / 2 / cam.ortho) if cam.ortho else cam.F / Pc[2]
            bw, bh = sw * scale, sh * scale
            if bh < 5 * ss:
                continue
            f, fs = fit_text(text, bw, bh, stroke=0.06)
            tex = Image.new("RGBA", (int(bw) + 8, int(bh) + 8), (0, 0, 0, 0))
            d = ImageDraw.Draw(tex)
            sw_px = max(1, int(fs * 0.06))
            b = d.textbbox((0, 0), text, font=f, stroke_width=sw_px)
            d.text(((tex.width - (b[2] - b[0])) / 2 - b[0], (tex.height - (b[3] - b[1])) / 2 - b[1]), text, font=f,
                   fill=rgb + (255,), stroke_width=sw_px, stroke_fill=stroke + (255,))
            x0, y0 = int(px[0] - tex.width / 2), int(py[0] - tex.height / 2)
            a = np.asarray(tex, np.float32) / 255.0
            X0, Y0 = max(0, x0), max(0, y0)
            X1, Y1 = min(W, x0 + tex.width), min(H, y0 + tex.height)
            if X1 <= X0 or Y1 <= Y0:
                continue
            sub = a[Y0 - y0:Y1 - y0, X0 - x0:X1 - x0]
            depth = Pc[2] if not cam.ortho else -1e9
            visible = zc[Y0:Y1, X0:X1] > depth - 0.5
            alpha = sub[..., 3] * visible
            reg = img[Y0:Y1, X0:X1]
            reg[:] = reg * (1 - alpha[..., None]) + sub[..., :3] * alpha[..., None]


# ------------------------------------------------------------------------------------------
# Render
# ------------------------------------------------------------------------------------------
SUN_COLOR = np.array([1.0, 0.96, 0.9]) * 0.46
SKY_AMBIENT = np.array([0.68, 0.73, 0.82])
GROUND_AMBIENT = np.array([0.6, 0.61, 0.66])
FOG_COLOR = np.array([214, 228, 240]) / 255.0
SKY_TOP = np.array([0.36, 0.6, 0.9])
SKY_HORIZON = np.array([0.80, 0.88, 0.96])


def sky(cam: Camera):
    xn, yn = cam.pixel_rays()
    if cam.ortho:
        return np.broadcast_to(SKY_HORIZON, (cam.H, cam.W, 3)).copy()
    d = xn[..., None] * cam.r + yn[..., None] * cam.u + cam.f
    d = d / np.linalg.norm(d, axis=-1, keepdims=True)
    t = np.clip(d[..., 1], 0, 1) ** 0.6
    return SKY_HORIZON + (SKY_TOP - SKY_HORIZON) * t[..., None]


def shadow_factor(P, n, region_mask, casters, sun, light_res=2560, log=print):
    """Directional shadow map fitted to the receiving pixels; returns 1 = lit, 0 = shadow."""
    out = np.ones(len(P))
    if not region_mask.any():
        return out
    lz = -sun
    lx = unit(np.cross(lz, [0, 1, 0]))
    ly = np.cross(lx, lz)
    Q = P[region_mask]
    u, v = Q @ lx, Q @ ly
    umin, umax, vmin, vmax = u.min() - 2, u.max() + 2, v.min() - 2, v.max() + 2
    texel = max(umax - umin, vmax - vmin) / light_res
    texel = max(texel, 0.04)
    Wl = int(math.ceil((umax - umin) / texel)) + 1
    Hl = int(math.ceil((vmax - vmin) / texel)) + 1
    tris = casters
    U, V, D = tris @ lx, tris @ ly, tris @ lz
    keep = (U.max(1) >= umin) & (U.min(1) <= umax) & (V.max(1) >= vmin) & (V.min(1) <= vmax)
    U, V, D = U[keep], V[keep], D[keep]
    xs, ys = (U - umin) / texel, (vmax - V) / texel
    zb, _ = raster(xs, ys, D, np.arange(len(U)), Wl, Hl)
    zb = zb.reshape(Hl, Wl)
    # Normal offset + constant bias, 3x3 PCF.
    Qo = Q + n[region_mask] * (texel * 1.5) + sun * 0.05
    qu, qv, qd = (Qo @ lx - umin) / texel, (vmax - Qo @ ly) / texel, Qo @ lz
    # 4x4 tent-filtered PCF: smooth shadow edges instead of texel stair steps.
    bx, by = np.floor(qu - 0.5), np.floor(qv - 0.5)
    fx, fy = qu - 0.5 - bx, qv - 0.5 - by
    wxs = [1 - fx, np.ones_like(fx), np.ones_like(fx), fx]
    wys = [1 - fy, np.ones_like(fy), np.ones_like(fy), fy]
    lit = np.zeros(len(Q))
    for a, ox in enumerate((-1, 0, 1, 2)):
        ix = np.clip(bx + ox, 0, Wl - 1).astype(int)
        for b, oy in enumerate((-1, 0, 1, 2)):
            iy = np.clip(by + oy, 0, Hl - 1).astype(int)
            lit += wxs[a] * wys[b] * (qd <= zb[iy, ix] + texel * 1.2 + 0.08)
    out[region_mask] = lit / 9
    log(f"  shadow map {Wl}x{Hl}, texel {texel:.3f} studs, {keep.sum()} casters")
    return out


def sun_for(cam: Camera, preset: dict):
    """Key light per shot (the in-game sun moves with the day cycle): `sun` = (azimuth from
    behind the camera towards its left, elevation), both in degrees."""
    az, el = preset.get("sun", (35.0, 48.0))
    back = -cam.f.copy()
    back[1] = 0
    if np.linalg.norm(back) < 1e-6:
        back = -cam.u.copy()
        back[1] = 0
    back = unit(back)
    left = unit(np.cross([0, 1, 0], back))
    a, e = math.radians(az), math.radians(el)
    h = back * math.cos(a) + left * math.sin(a)
    return unit(h * math.cos(e) + np.array([0, 1.0, 0]) * math.sin(e))


def point_lights(s: Scene, Pw, n, dist, max_dist):
    """PointLight / SpotLight contributions (no shadows; SpotLights treated as point lights)."""
    out = np.zeros((len(Pw), 3))
    for cls, pid, rng, bright, r, g, b in s.lights:
        i = s.index_of.get(pid)
        if i is None:
            continue
        c = s.pos[i]
        near = np.nonzero((np.abs(Pw - c) <= rng).all(1) & (dist < max_dist + rng))[0]
        if len(near) == 0:
            continue
        d = c - Pw[near]
        L = np.linalg.norm(d, axis=1)
        att = np.clip(1 - L / rng, 0, 1) ** 2 * bright * 0.45
        ndl = np.clip((n[near] * d).sum(1) / np.maximum(L, 1e-6), 0, 1) * 0.8 + 0.2
        out[near] += (att * ndl)[:, None] * np.array([r, g, b])
    return out


def terrain_in_view(s: Scene, cam: Camera, max_dist):
    tri, n, vn, mat = s.terrain
    cen = tri.mean(1)
    q = cam.to_cam(cen.astype(np.float64))
    r = 6.0
    if cam.ortho:
        hw = cam.ortho * cam.W / cam.H
        keep = (np.abs(q[:, 0]) <= hw + r) & (np.abs(q[:, 1]) <= cam.ortho + r)
    else:
        tx, ty = (cam.W / 2) / cam.F, (cam.H / 2) / cam.F
        keep = (q[:, 2] > -r) & (np.abs(q[:, 0]) - tx * q[:, 2] < r * 1.5) & (np.abs(q[:, 1]) - ty * q[:, 2] < r * 1.5)
        keep &= np.linalg.norm(cen - cam.pos, axis=1) < max_dist
    idx = np.nonzero(keep)[0]
    return tri[idx].astype(np.float64), n[idx].astype(np.float64), vn[idx], mat[idx]


def barycentric(P, T):
    e0, e1, ep = T[:, 1] - T[:, 0], T[:, 2] - T[:, 0], P - T[:, 0]
    d00, d01, d11 = (e0 * e0).sum(1), (e0 * e1).sum(1), (e1 * e1).sum(1)
    d20, d21 = (ep * e0).sum(1), (ep * e1).sum(1)
    den = d00 * d11 - d01 * d01
    den = np.where(np.abs(den) < 1e-12, 1, den)
    b1 = np.clip((d11 * d20 - d01 * d21) / den, 0, 1)
    b2 = np.clip((d00 * d21 - d01 * d20) / den, 0, 1)
    b0 = np.clip(1 - b1 - b2, 0, 1)
    return np.stack([b0, b1, b2], 1)


def render(s: Scene, preset: dict, out_path: str, W=1280, H=720, ss=2, log=print):
    t0 = time.time()
    Wss, Hss = W * ss, H * ss
    cam = Camera(preset["pos"], preset["target"], Wss, Hss, fov=preset.get("fov", 70), ortho=preset.get("ortho"),
                 up=preset.get("up", (0, 1, 0)), near=preset.get("near", 0.1))
    sun = sun_for(cam, preset) if not preset.get("sun_world") else unit(np.array(preset["sun_world"], float))
    # Parts: visible ones (transparency < 0.95) the camera can see.
    vis = s.transp < 0.95
    hide = preset.get("hide", ())
    for i in range(s.n):
        if vis[i] and any(s.path[i].startswith(h) for h in hide):
            vis[i] = False
    radius = np.linalg.norm(s.size, axis=1) / 2 * np.maximum(1, np.abs(s.ms).max(1))
    for i in np.nonzero(vis)[0]:
        if not cam.sphere_visible(s.pos[i], radius[i]):
            vis[i] = False
    ptris, pn, powner = build_part_tris(s, vis)
    ttris, tn, tvn, tmat = terrain_in_view(s, cam, preset.get("terrain_dist", 7000))
    nparts = len(ptris)
    tris = np.concatenate([ptris, ttris])
    normals = np.concatenate([pn, tn])
    owner = np.concatenate([powner, np.full(len(ttris), -1)])
    log(f"  {nparts} part triangles ({vis.sum()} parts), {len(ttris)} terrain triangles")
    # Back-face culling (parts and terrain are closed, outward-wound surfaces).
    cen = tris.mean(1)
    if cam.ortho:
        keep = normals @ cam.f < 1e-6
    else:
        keep = ((cen - cam.pos) * normals).sum(1) < 1e-6
    src = np.nonzero(keep)[0]
    Pc = cam.to_cam(tris[src])
    if cam.ortho:
        Pc2, src2 = Pc, src
    else:
        Pc2, src2 = clip_near(Pc, cam.near, src)
    px, py, key = cam.project(Pc2)
    zbuf, idbuf = raster(px, py, key, src2, Wss, Hss)
    log(f"  raster {time.time() - t0:.1f}s")
    hit = idbuf >= 0
    tri_id = idbuf[hit]
    keyimg = zbuf.reshape(Hss, Wss)
    Pw, zc = cam.world_from_key(np.where(np.isfinite(keyimg), keyimg, (0 if cam.ortho else -1e-9)))
    Pw = Pw.reshape(-1, 3)[hit]
    zc = zc.reshape(-1)
    n = normals[tri_id].copy()
    own = owner[tri_id]
    is_terrain = own < 0
    ti = np.nonzero(is_terrain)[0]
    # Albedo.
    albedo = np.zeros((len(tri_id), 3), np.float32)
    pi = own[~is_terrain]
    albedo[~is_terrain] = s.color[pi]
    mats = s.material[pi]
    tint = np.ones(len(pi), np.float32)
    for name, f in PART_TINT.items():
        tint[mats == name] = f
    albedo[~is_terrain] *= tint[:, None]
    glacier_parts = mats == "Glacier"
    if glacier_parts.any():
        idx = np.nonzero(~is_terrain)[0][glacier_parts]
        albedo[idx] = terrain_albedo(s, Pw[idx], n[idx], np.full(len(idx), 1))
    if len(ti):
        k = tri_id[ti] - nparts
        b = barycentric(Pw[ti], ttris[k])
        sn = (tvn[k] * b[:, :, None]).sum(1)
        sn /= np.maximum(np.linalg.norm(sn, axis=1, keepdims=True), 1e-9)
        n[ti] = sn
        vm = tmat[k]
        same = (vm[:, 0] == vm[:, 1]) & (vm[:, 1] == vm[:, 2])
        alb = terrain_albedo(s, Pw[ti], sn, vm[:, 0])
        mix = np.nonzero(~same)[0]
        if len(mix):
            alb[mix] *= b[mix, 0, None]
            for v in (1, 2):
                alb[mix] += b[mix, v, None] * terrain_albedo(s, Pw[ti][mix], sn[mix], vm[mix, v])
        albedo[ti] = alb
    neon = np.zeros(len(tri_id), bool)
    neon[~is_terrain] = mats == "Neon"
    # Lighting: hemisphere ambient + sun with a shadow map.
    sd = preset.get("shadow_dist", 500)
    dist = np.linalg.norm(Pw - cam.pos, axis=1)
    region = dist < sd
    caster_sel = np.zeros(len(tris), bool)
    caster_sel[owner < 0] = True
    pm = owner >= 0
    caster_sel[pm] = s.shadow[owner[pm]]
    flat_n = normals[tri_id]
    # Two cascades: a fine map near the camera, a coarser one for the rest of the range.
    split = preset.get("cascade", min(70.0, sd))
    casters = tris[caster_sel]
    sh = shadow_factor(Pw, flat_n, region & (dist < split), casters, sun, log=log)
    if sd > split:
        sh = sh * shadow_factor(Pw, flat_n, region & (dist >= split), casters, sun, log=log)
    fade = np.clip((dist - sd * 0.8) / (sd * 0.2), 0, 1)
    sh = sh + (1 - sh) * fade
    ndl = np.clip(n @ sun, 0, 1)
    hemi = 0.5 + 0.5 * n[:, 1]
    light = SKY_AMBIENT * hemi[:, None] + GROUND_AMBIENT * (1 - hemi[:, None]) + SUN_COLOR * (ndl * sh)[:, None]
    light += point_lights(s, Pw, n, dist, sd)
    col = albedo * light
    col[neon] = np.minimum(albedo[neon] * 1.25 + 0.1, 1)
    # Fog (Atmosphere-like): exponential with distance, towards the haze colour.
    fd = preset.get("fog", 1.0)
    if not cam.ortho and fd > 0:
        f = 1 - np.exp(-np.maximum(dist - 30, 0) * fd / 1500)
        f = np.clip(f, 0, 0.9)
        col = col + (FOG_COLOR - col) * f[:, None]
    img = sky(cam).reshape(-1, 3)
    img[hit] = np.clip(col, 0, 1)
    img = img.reshape(Hss, Wss, 3)
    owner_pix = np.full(Wss * Hss, -2, np.int64)
    owner_pix[hit] = own
    owner_pix = owner_pix.reshape(Hss, Wss)
    zc_img = np.where(hit, zc, np.inf).reshape(Hss, Wss) if not cam.ortho else np.zeros((Hss, Wss))
    draw_texts(s, cam, img, owner_pix, zc_img, ss)
    if preset.get("overlay"):
        img = preset["overlay"](s, cam, img)
    small = img.reshape(H, ss, W, ss, 3).mean((1, 3))
    Image.fromarray((np.clip(small, 0, 1) * 255 + 0.5).astype(np.uint8)).save(out_path)
    log(f"  wrote {out_path} ({time.time() - t0:.1f}s)")


# ------------------------------------------------------------------------------------------
# Presets
# ------------------------------------------------------------------------------------------
def at(s, x, z, dy=0.0):
    return (x, float(ground(s, x, z)) + dy, z)


def route_overlay(s: Scene, cam: Camera, img):
    pil = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(pil)
    sc = cam.H / 2 / cam.ortho
    k = cam.W / 1280

    def to_px(x, y, z):
        Pc = cam.to_cam(np.array([[x, y, z]], np.float64))
        px, py, _ = cam.project(Pc)
        return float(px[0]), float(py[0])

    styles = {"Walk": ((220, 40, 40), 3), "Bridge": ((150, 95, 40), 6), "Ladder": ((40, 40, 50), 6)}
    for name in sorted(set(r[0] for r in s.route)):
        pts = [r for r in s.route if r[0] == name]
        for a, b in zip(pts[:-1], pts[1:]):
            colr, w = styles.get(b[5], styles["Walk"])
            if name != "Main":
                colr = (250, 140, 30)
            d.line([to_px(a[2], a[3], a[4]), to_px(b[2], b[3], b[4])], fill=colr, width=int(w * k))
    f = font(22 * k)
    small = font(16 * k)
    labels = [(c[1], c[2], c[3], c[4]) for c in s.camps]
    summit = [r for r in s.route if r[6] == "Summit"]
    if summit:
        labels.append(("Summit", summit[0][2], summit[0][3], summit[0][4]))
    for text, x, y, z in labels:
        cx, cy = to_px(x, y, z)
        r = 9 * k
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(40, 220, 60), outline=(255, 255, 255), width=int(3 * k))
        elev = 300 + 4 * y
        d.text((cx, cy - 16 * k), f"{text}", font=f, fill=(0, 70, 140), anchor="ms", stroke_width=int(3 * k),
               stroke_fill=(255, 255, 255))
        d.text((cx, cy + 26 * k), f"{elev:.0f} m", font=small, fill=(0, 70, 140), anchor="ms",
               stroke_width=int(2 * k), stroke_fill=(255, 255, 255))
    # Legend.
    x0, y0 = 20 * k, cam.H - 120 * k
    d.rounded_rectangle([x0, y0, x0 + 300 * k, y0 + 100 * k], radius=12 * k, fill=(0, 110, 200),
                        outline=(255, 255, 255), width=int(3 * k))
    items = [("route (walk)", (220, 40, 40)), ("rope bridge", (150, 95, 40)), ("ladder", (40, 40, 50)),
             ("ice wall bypass", (250, 140, 30))]
    for j, (label, c) in enumerate(items):
        yy = y0 + (14 + j * 21) * k
        d.line([(x0 + 14 * k, yy + 8 * k), (x0 + 54 * k, yy + 8 * k)], fill=c, width=int(5 * k))
        d.text((x0 + 64 * k, yy), label, font=small, fill=(255, 255, 255))
    d.text((cam.W - 20 * k, 20 * k), "uphill (+Z) →", font=f, fill=(0, 70, 140), anchor="ra",
           stroke_width=int(3 * k), stroke_fill=(255, 255, 255))
    return np.asarray(pil, np.float32) / 255.0


def presets(s: Scene):
    def char(name):
        x, y, z, yaw = s.chars[name]
        return x, y, z, math.radians(yaw)

    px_, py_, pz_, pyaw = char("Player")
    cx, cy, cz, _ = char("Closeup")
    camp = {c[0]: c for c in s.camps}
    c1 = camp["Camp1"]
    route = {r[6]: r for r in s.route if r[6] != "-"}
    wf = route["WallFoot"]
    k1 = route["K1S"]
    summit = route["Summit"]
    t4 = route["T4"]
    # Behind the player: opposite their look vector (-sin yaw, -cos yaw).
    lx, lz = -math.sin(pyaw), -math.cos(pyaw)
    return {
        "basecamp_overview": dict(pos=(74, 44, 80), target=(-6, 0, -14), fov=52, shadow_dist=420,
                                  desc="Base Camp from a high 3/4 angle, like the title screen."),
        "basecamp_ground": dict(pos=(px_ - lx * 12 + 1.5, py_ + 7, pz_ - lz * 12),
                                target=(px_ + lx * 20, py_ + 4.5, pz_ + lz * 20), fov=70, shadow_dist=350,
                                desc="Third-person view behind the player, facing the equipment tent."),
        "equipment_tent_interior": dict(pos=at(s, -21, -29.5, 6.2), target=at(s, -30, -49, 3.6), fov=75,
                                        shadow_dist=200, hide=("Player",), sun=(60, 55),
                                        desc="Inside the equipment tent: counter, mannequins, EQUIPMENT banner."),
        "camp1": dict(pos=(c1[2] + 42, c1[3] + 24, c1[4] - 44), target=(c1[2] - 2, c1[3] + 2, c1[4] + 8), fov=60,
                      shadow_dist=300, desc="Camp 1 on its shelf above the Headwall."),
        "crevasse_bridges": dict(pos=(k1[2] - 10, k1[3] + 14, k1[4] - 34), target=(k1[2] + 60, k1[3] - 6, k1[4] + 110),
                                 fov=70, shadow_dist=500,
                                 desc="Crossing the crevasse field: rope bridges, looking north up the route."),
        "ice_wall_ladder": dict(pos=(wf[2] + 6, wf[3] + 6, wf[4] - 36), target=(wf[2], wf[3] + 20, wf[4] + 4),
                                fov=70, shadow_dist=300, sun=(20, 40),
                                desc="The 48-stud ice wall and its ladder, from behind a climber at its foot."),
        "ridge": dict(pos=(38, 478, 3030), target=(-150, 515, 3380), fov=70, shadow_dist=700,
                      desc="The knife-edge ridge from the north edge of Camp 2."),
        "summit": dict(pos=(summit[2] + 40, summit[3] + 18, summit[4] - 64), target=(summit[2], summit[3] + 4,
                                                                                     summit[4]), fov=65,
                       shadow_dist=300, desc="The summit pad with the flag and cairn, from the last pitch."),
        "character_front": dict(pos=(cx + 2.0, cy + 4.4, cz - 10.5), target=(cx, cy + 3.0, cz), fov=46, near=0.05,
                                shadow_dist=60, sun=(150, 45), desc="Default-loadout character from the front."),
        "character_back": dict(pos=(cx - 2.4, cy + 4.8, cz + 10.5), target=(cx, cy + 3.1, cz), fov=46, near=0.05,
                               shadow_dist=60, desc="Default-loadout character from behind (pack, harness, axe)."),
        "valley": dict(pos=(30, 34, 90), target=(-10, 70, 700), fov=68, shadow_dist=900,
                       desc="Leaving Base Camp: the snow valley and its peaks, looking up the route."),
        "headwall": dict(pos=(60, 70, 780), target=(0, 140, 1250), fov=68, shadow_dist=900,
                         desc="The Headwall switchbacks from the top of the valley."),
        "serac_band": dict(pos=(t4[2] - 40, t4[3] + 16, t4[4] - 30), target=(t4[2] - 200, t4[3] + 60, t4[4] + 120),
                           fov=68, shadow_dist=600, desc="The glacier switchbacks under the serac band."),
        "summit_view": dict(pos=(summit[2] + 6, summit[3] + 8, summit[4] + 4), target=(0, 300, 2300), fov=70,
                            shadow_dist=1500, desc="From the summit, looking back down the whole route."),
        "vista": dict(pos=(1100, 1050, -500), target=(-80, 250, 2000), fov=55, shadow_dist=4000,
                      desc="The whole mountain from the air, south-east of Base Camp."),
        "route_map": dict(pos=(0, 3000, 1900), target=(0, 0, 1900), map=True,
                          desc="Top-down map of the whole route with the camps marked."),
    }


def finalize_preset(s, name, p):
    if p.get("map"):
        # Orthographic, looking straight down, +Z (uphill) to the right of the image.
        zs = [r[4] for r in s.route]
        z0, z1 = min(zs) - 260, max(zs) + 260
        p["pos"] = (0, 3000, (z0 + z1) / 2)
        p["target"] = (0, 0, (z0 + z1) / 2)
        p["up"] = (1, 0, 0)
        p["ortho"] = (z1 - z0) / 2 * 720 / 1280
        p["lod"] = [(1e9, 4)]
        p["shadow_dist"] = 1e9
        p["overlay"] = route_overlay
        p["fog"] = 0
        p["sun_world"] = (0.35, 0.88, -0.3)
    return p


def prepare(path: str, work: str) -> Scene:
    s = load_scene(path)
    s.terrain = terrain.heightfield_mesh(s.gx0, s.gz0, s.gstep, s.H, s.M, s.B)
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("presets", nargs="*")
    ap.add_argument("--work", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "game-render"))
    ap.add_argument("--out", default=os.path.join(REPO, "docs", "previews"))
    ap.add_argument("--no-dump", action="store_true", help="reuse <work>/scene.tsv")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--ss", type=int, default=2, help="supersampling factor (default 2)")
    ap.add_argument("--size", default="1280x720")
    args = ap.parse_args()
    path = os.path.join(args.work, "scene.tsv")
    if not args.no_dump or not os.path.exists(path):
        path = run_dump(args.work)
    s = prepare(path, args.work)
    for w in s.warns:
        print("WARN:", w)
    ps = presets(s)
    if args.list:
        for k, v in ps.items():
            print(f"{k:26s} {v['desc']}")
        return
    W, H = (int(v) for v in args.size.split("x"))
    os.makedirs(args.out, exist_ok=True)
    for name in args.presets or list(ps):
        if name not in ps:
            sys.exit(f"unknown preset {name}; try --list")
        print(name)
        render(s, finalize_preset(s, name, dict(ps[name])), os.path.join(args.out, name + ".png"), W, H, args.ss)


if __name__ == "__main__":
    main()
