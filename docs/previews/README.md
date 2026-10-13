# Approximate previews (not Roblox screenshots)

> **These images are NOT screenshots from Roblox.** They come from our own small offline
> renderer (`tests/render/`), written so the world can be looked at without Roblox Studio.
> They show **our geometry**: every part the builders create, at its real size, position,
> colour and material, plus the terrain heightfield the builder writes. They do **not** show how Roblox
> will light or texture it.
>
> Not in these images: Roblox lighting (Future/ShadowMap lighting, ambient occlusion,
> specular, bloom), the real `Atmosphere`, fog and sky, material textures (Snow sparkle,
> Glacier cracks, wood grain, fabric weave), particles and effects (`Fire`, `Smoke`,
> `ParticleEmitter`, snowfall, wind streaks, footprints, breath), all UI and HUD, animations
> (characters stand in the rest pose) and the real FredokaOne font. Treat colours and
> brightness as roughly right, shapes and placement as exact.

## The images (1280x720)

| File | What it shows |
|---|---|
| `basecamp_overview.png` | Base Camp from a high 3/4 angle (like the title screen): equipment tent, sleeping tent, rescue station, ring of tents, campfire, flags, lamps, crates, checkpoint ring, "Base Camp" label. |
| `basecamp_ground.png` | Third-person view behind a player in the default loadout, walking up to the equipment tent. |
| `equipment_tent_interior.png` | Inside the equipment tent: carpet, counter, mannequins (jackets, packs, helmet, boots) and the EQUIPMENT banner. |
| `valley.png` | Leaving Base Camp: the snow valley, pines, trail markers and the peaks either side. |
| `headwall.png` | The Headwall switchbacks seen from the top of the valley. |
| `camp1.png` | Camp 1 on the lip above the Headwall: group tent, small tents, fire, crates, sign, checkpoint. |
| `crevasse_bridges.png` | The crevasse plateau from Camp 1's side, a player about to cross the first rope bridge. |
| `ice_wall_ladder.png` | The 48-stud ice wall and its ladder, from behind a player at its foot. |
| `serac_band.png` | The glacier switchbacks under the serac band (the serac-fall hazard). |
| `ridge.png` | The knife-edge ridge (rope fences, markers) from the north edge of Camp 2. |
| `summit.png` | The summit pad with the flag, the cairn and the fixed rope of the last pitch. |
| `summit_view.png` | From the summit, looking back down the whole route. |
| `vista.png` | The whole mountain from the air, above the peaks south-east of Base Camp. |
| `character_front.png` | A player in the default loadout from the front (helmet + headlamp, goggles, mask, parka with fur ring, gloves, pants, boots). |
| `character_back.png` | The same player from behind: harness, stowed ice axe and the default expedition pack. |
| `route_map.png` | Top-down orthographic map of the whole route, uphill (+Z) to the right, camps and elevations marked; red = walked route, brown = rope bridges, black = ladders, orange = the ice-wall bypass. |

## How they are made

1. `luaurun tests/render/dump.luau <repo>` runs the **real** server code in a headless mock
   (`tests/render/RobloxMock.luau`): `WorldBuilder.build()` (which calls `CampKit.build`,
   `RouteKit`, `AssetFactory` exactly as in game) and `EquipmentService.refresh()` on an
   R15-sized dummy set up by `InventoryService.setupLoadout` (the gear a brand-new player
   gets). It prints every part, text label and light, and the terrain heightfield: every
   4-stud voxel column's height, top material and body material from `TerrainModel`.
2. `tests/render/terrain.py` meshes that heightfield (two triangles per column cell, smooth
   normals). Triangles take the columns' top material (Snow, or Glacier/Rock on steep
   columns); cliff faces between columns take the ice/rock body of the higher column, which
   is what a voxel cliff shows under its snow cap. Colours are `WorldBuilder`'s
   `SetMaterialColor` values.
3. `tests/render/render.py` rasterises everything with a numpy z-buffer: flat-shaded parts,
   smooth-shaded terrain, a sun with soft shadow maps, sky-tinted ambient light, part
   `PointLight`s, distance haze, a sky gradient, 2x2 supersampling, and `SurfaceGui` /
   `BillboardGui` text drawn on the right faces.

Shapes supported: Block, Wedge, CornerWedge, Cylinder, Ball, SpecialMesh Sphere / Head /
Brick, TrussPart (drawn as a lattice). Parts with Transparency >= 0.95 are hidden.

## Regenerate

Needs `luaurun` (see docs/TESTING.md), Python 3, numpy and Pillow.

```sh
python3 tests/render/render.py                      # all previews -> docs/previews/ (~8 min)
python3 tests/render/render.py camp1 summit         # just these
python3 tests/render/render.py --list               # preset names and descriptions
python3 tests/render/render.py --size 640x360 --ss 1 --out /tmp/prev   # fast drafts
python3 tests/render/checks.py                      # geometry diagnostics (floating /
                                                    # buried parts, clashes, camp overlaps)
```

Intermediate files (the scene dump) go to `$TMPDIR/game-render`
(override with `--work`).

## Known differences from the game

- **Random scatter differs.** The mock's `Random` is not Roblox's generator, so the exact
  spots of scattered trees and rocks (and the small colour jitter of props) differ from a real
  server; the placement rules (clusters, slope, trail clearance, camp exclusion) are the real
  ones.
- **Terrain smoothing is ours.** The heightfield is the same, but Roblox's smooth-terrain
  mesher rounds edges differently, and its cliffs stand at voxel boundaries where ours slope
  across one 4-stud cell.
- **Characters** are a classic R15 block rig (scale 1, classic head) in the rest pose.
- **Lighting** is a per-shot key light (the game's sun moves with its day cycle), not the
  game's `ClockTime`.
