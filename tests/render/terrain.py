"""Terrain mesh for the preview renderer.

The game's terrain is a heightfield on Roblox's 4-stud voxel grid (Shared/Logic/TerrainModel):
WorldBuilder writes every column solid up to its height with WriteVoxels, the top voxel partly
filled, so smooth terrain follows the bilinear surface between column centres. The dump
(dump.luau) emits each column's height, top material and body material; this module turns
them into a triangle mesh: two triangles per grid cell, smooth vertex normals from the grid
gradient, and per-vertex materials. Triangles take each vertex's top material, except cliff
faces between columns (steeper than 60 degrees), which take the body material of their highest
corner: what a voxel cliff shows below its snow cap.
"""
from __future__ import annotations

import numpy as np

MAT_CODES = {"Snow": 0, "Glacier": 1, "Rock": 2, "Slate": 3, "Air": 4, "Ice": 5}
CLIFF_NY = np.cos(np.radians(60))  # steeper triangles are cliff faces between columns


def heightfield_mesh(x0, z0, step, H, top, body, log=print):
    """H, top, body: (nz, nx) arrays. Returns tri (T,3,3), n (T,3), vn (T,3,3), mat (T,3)."""
    nz, nx = H.shape
    xs = x0 + step * np.arange(nx)
    zs = z0 + step * np.arange(nz)
    X, Z = np.meshgrid(xs, zs)
    V = np.stack([X.ravel(), H.ravel().astype(np.float64), Z.ravel()], 1)
    # Vertex normals from central differences.
    gx = np.gradient(H.astype(np.float64), step, axis=1)
    gz = np.gradient(H.astype(np.float64), step, axis=0)
    vn = np.stack([-gx.ravel(), np.ones(nx * nz), -gz.ravel()], 1)
    vn /= np.linalg.norm(vn, axis=1, keepdims=True)
    idx = np.arange(nx * nz).reshape(nz, nx)
    a, b = idx[:-1, :-1].ravel(), idx[:-1, 1:].ravel()
    c, d = idx[1:, :-1].ravel(), idx[1:, 1:].ravel()
    # Wound so the normals point up (+y): (a, c, b) and (b, c, d) with x right, z down-grid.
    T = np.concatenate([np.stack([a, c, b], 1), np.stack([b, c, d], 1)])
    tri = V[T]
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
    flip = n[:, 1] < 0
    n[flip] *= -1
    tops, bodies = top.ravel(), body.ravel()
    mat = tops[T].copy()
    steep = n[:, 1] < CLIFF_NY
    hi = np.argmax(tri[:, :, 1], axis=1)
    mat[steep] = bodies[T[steep, hi[steep]]][:, None]
    log(f"  terrain mesh: {len(V)} vertices, {len(T)} triangles")
    return tri.astype(np.float32), n.astype(np.float32), vn[T].astype(np.float32), mat.astype(np.int8)
