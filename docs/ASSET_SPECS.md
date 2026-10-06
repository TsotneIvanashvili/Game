# Asset Production Specs

Status: production target for every greybox prop built in `src/server/World/AssetFactory.luau` and every piece of character gear mounted by `src/server/Services/EquipmentService.luau`.
Audience: 3D artists, outsourcers and 3D-generation tools. Every number here is either taken from the greybox code (and therefore a **code contract**) or is a real-world measurement of the product category being modelled.

Contents

1. Global conventions (scale, axes, pivots, palette, texel density, shared atlases, weather contract)
2. Full asset specs: Expedition backpack (+ tiers, harness, hip belt, stowed bundles) · Ice axe · Dynamic rope · Locking carabiner · Crampons · Mountaineering boots · Insulated parka (+ clothing family notes) · Alpine expedition tent · Campfire · Emergency tarp shelter · Wind wall · Trail marker
3. Family specs: Rocks · Pine trees · Snow states · Ice
4. Realism quality gate (15 questions)
5. Roblox implementation notes
6. Code follow-ups found while writing these specs

---

## 1. Global conventions

### 1.1 Scale

| Quantity | Value | Source |
|---|---|---|
| R15 character height | ≈ 5 studs | engine default rig |
| R15 UpperTorso | ≈ 2 × 1.6 × 1 studs (W × H × D) | `AssetFactory.luau` header comment |
| Engine convention | 1 stud ≈ 0.28 m | Roblox physics/gravity convention |
| Character-relative factor | 1 stud ≈ 0.35 m (a 1.75 m adult mapped onto 5 studs) | this document |

The R15 rig is short for the 0.28 m convention (5 × 0.28 = 1.4 m) and broader across the shoulders than a real adult. Converting real gear at 0.28 m/stud makes it 25% too large on the body; converting at 0.35 m/stud makes handheld items look slightly small in the rig's oversized hands. Rules:

1. Every spec lists **real meters**, **studs @ 0.28**, **studs @ 0.35**, and the **target studs**. The target is authoritative.
2. Where the greybox already fixes a size (pack tiers, axe grip-to-head distance, tarp footprint), the target equals the greybox, because anchor CFrames in code depend on it.
3. **Heights and lengths** follow the character-relative band (between the two conversions). **Widths of worn gear** are fitted to the R15 body (e.g. pack width is a fraction of the 2-stud torso), not converted.
4. Thin real features that would fall below ~0.03 studs (rope diameter, webbing thickness, stitch width) are exaggerated by a stated factor (normally 1.5–2.5×) so they survive at 30 studs camera distance. The factor is stated in each spec. Nothing else is exaggerated.

### 1.2 Axes, spaces and pivots

Roblox is +Y up; characters face −Z, so +X is the wearer's right.

| Space | Origin | Axes | Used by |
|---|---|---|---|
| Pack space | Centre of the wearer's back surface (UpperTorso centre + Z/2) | +Z away from the body, +Y up, +X wearer's right | `AssetFactory.backpack` and its anchors |
| Torso space | UpperTorso centre | as UpperTorso | `AssetFactory.harness` |
| Lower-torso space | LowerTorso centre | as LowerTorso | `AssetFactory.hipBelt` |
| Axe grip space | Centre of the hand's closed grip on the shaft | +Y toward the head, −Z toward the pick, +Z toward the adze | `AssetFactory.iceAxe` (held and stowed) |
| Bundle space | Bundle centre | see each bundle | rope coil, tarp roll, wood bundle |
| World-prop space | Ground contact point under the prop's centre (`at`) | +Y up | campfire, tarp shelter, wind wall, trail marker, rocks, trees |

Export every mesh so that its origin is that space's origin. When imported and parented as the code does today, the mesh must overlap the greybox to within 0.02 studs. Check this by overlaying the greybox in Studio before handing off. Set the importer's unit option so that one modelling unit becomes one stud. The available importer unit options change between Studio versions, so read them in the current importer.

### 1.3 Palette (tints are owned by `ItemDefs.luau`)

The code sets each item's dominant fabric colour. The art supplies everything else: value variation, dirt, wear, hardware colour. See 5.3 for how a code-driven tint and a SurfaceAppearance coexist.

| Item | ItemDefs colour (RGB) |
|---|---|
| Daypack (Small) | 60, 90, 140 |
| Alpine Pack (Medium) | 170, 60, 40 |
| Mountaineering Pack (Large) | 40, 110, 80 |
| Expedition Pack (85 L) | 220, 150, 30 |
| Ice axe shaft anodise | 70, 110, 170 |
| Rope | 220, 110, 40 |
| Tarp | 60, 110, 70 |
| Insulated parka | 200, 70, 40 |
| Hardshell | 210, 170, 30 |
| Fleece | 60, 120, 160 |
| Merino base / cotton tee | 70, 70, 90 / 200, 200, 200 |
| Liner / insulated gloves | 50, 50, 50 / 30, 30, 35 |
| Hiking / insulated pants | 90, 85, 70 / 30, 40, 60 |
| Trail runners / alpine boots | 90, 160, 90 / 110, 40, 30 |
| Wool beanie / balaclava | 150, 40, 40 / 40, 40, 45 |

Hardware is never tinted: webbing is near-black nylon (sRGB 28–35), buckles are black acetal (15–22), zip coils are black (25).

**PBR value ranges.** Albedo is sRGB. Roughness and metalness are linear 0–1.

| Material | Albedo range | Metalness | Roughness |
|---|---|---|---|
| PU-coated nylon ripstop (pack, shell) | item tint ± 6% value | 0 | 0.55–0.70 |
| 1000D abrasion nylon (pack base) | 40–55 grey-brown | 0 | 0.75–0.85 |
| Nylon webbing | 28–35 | 0 | 0.65–0.75 |
| Acetal / nylon buckle | 15–22 | 0 | 0.35–0.50 (edges 0.30 from handling) |
| Anodised aluminium (axe shaft, carabiner) | tint, ±4% | 1 | 0.30–0.40 (worn to 0.20 on high points) |
| Bare / worn aluminium | 170–190 | 1 | 0.25–0.45 |
| Forged chromoly steel (axe head, crampons) | 120–150 | 1 | 0.35–0.55 (sharpened edges 0.20, rust spots 0.85 non-metal) |
| Rubber (grip, boot rand, sole) | 22–30 | 0 | 0.80–0.90 |
| Full-grain leather (boots, glove palms) | item tint, darker at creases | 0 | 0.45–0.65 (waxed) |
| Wool / fleece knit | item tint | 0 | 0.90–1.00 |
| Bark (pine) | 55–90 brown-grey | 0 | 0.85–0.95 |
| Split wood (fresh face) | 160–190 warm yellow | 0 | 0.75 |
| Charcoal | 18–28 | 0 | 0.90 |
| Granite / gneiss rock | 95–130 grey | 0 | 0.75–0.90 (wet 0.30–0.45) |
| Fresh snow | 235–245 (slightly blue in shade) | 0 | 0.80–0.90 |
| Glacier / blue ice | 140–200 blue-cyan | 0 | 0.10–0.30 |

### 1.4 Texel density and budgets

Roblox currently downsamples uploaded images to a maximum of 1024 × 1024. Every resolution in this document is ≤ 1024.

| Class | Texel density | Map size | LOD0 tris |
|---|---|---|---|
| Hero worn gear (pack, parka, boots) | 256–400 px/stud | 1024 | 3,000–5,000 |
| Hand-held / small gear (axe, carabiner, crampons) | 400–600 px/stud | 512–1024 | 800–3,000 |
| Built world props (tent, tarp, fire, wind wall) | 96–160 px/stud | 1024 | 2,000–6,000 |
| Natural set dressing (rocks, trees) | 48–128 px/stud | 512–1024 | 300–6,000 |
| Terrain MaterialVariants | 64–128 px/stud (via StudsPerTile) | 1024 | n/a |

**Per-character budget:** all worn and stowed gear on one fully kitted character ≤ 18,000 triangles at LOD0, and ≤ 10 SurfaceAppearances. Share them through the atlases below.

### 1.5 Shared atlases and trim sheets

| Atlas | Size | Contents | Used by |
|---|---|---|---|
| `TRIM_Webbing_Hardware` | 1024² | Webbing strips (20 / 25 / 38 / 50 mm) with weave normal and bar-tack ends; side-release buckles (25 / 38 / 50 mm); ladder-locks; tri-glides; D-rings; #5 and #8 coil zip tape with teeth normal; zip pulls with cord tabs; cord locks; grommets; 3 mm cord; stitch rows (single, double, bar-tack, box-X) | pack, harness, hip belt, parka zips, tent, tarp, gloves, boots laces |
| `ATLAS_Metal` | 1024² | Anodised aluminium (blue, grey, red), bare aluminium, forged steel, stamped steel, rivets, hammered and filed edges, rust bloom | ice axe, carabiner, crampons, tent and tarp stakes, tent poles, pack frame stays (hidden) |
| `TILE_Fabric_Ripstop` | 512², tiles | Ripstop grid normal (5 mm grid → ≈ 7 px pitch at hero density), PU-coating roughness noise | every nylon shell (UV-tiled detail inside each asset's own 1024 map, see 5.3) |
| `ATLAS_Wood_Bark` | 1024² | Pine bark (plates), split wood faces with growth rings, saw-cut end grain, charred alligator crack, ash | campfire, wind wall, trail marker stake, tarp poles, wood bundle, tree trunks (detail) |
| `ATLAS_Snow_Overlay` | 512² | Up-facing snow shells: soft-edged accumulation, wind-scoured edge, melt-glazed edge, all alpha-cut | SnowCap, RoofSnow, rock and bough snow caps |

### 1.6 Weather-response contract (behaviour the code already drives)

| Effect | Code driver | What the art must do |
|---|---|---|
| Wet darkening | `EquipmentService.applyWetness`: every clothing shell and the pack's `Body`, `UpperBody` and `Lid` get `Color × (1 − 0.35 × wetness)`, in 10 steps | Albedo must carry its variation in **value relative to the tint**, so a 35% darker tint still reads. Never bake highlights brighter than 85% value, or soaked fabric looks chalky. See 5.3 for the tint mechanism. |
| Snow on pack | `SnowCap` part, a direct child of the `Backpack` model; Transparency eases from 1 to 0.05 during exposed snowfall; it melts faster near fire | `SnowCap` is a separate MeshPart that sits on the top face of the lid. Tolerances are in the backpack spec. |
| Snow on shelter | `RoofSnow` parts, direct children of the `TarpShelter` model; Transparency = 1 − snow × 0.9 | Two RoofSnow MeshParts, one per tarp side, following the sagged tarp surface. |
| Static snow | `snowy` flag on trees above snowline − 10 and on rocks above the snowline | Snow-capped variants: separate cap meshes, or a baked snow variant (see the family specs). |
| Fire | `Fire`, `Smoke` and `PointLight` instances parented to `Embers` | Embers mesh is the emitter host. Keep a part named `Embers`. |

---

## 2. Full asset specs

### 2.1 Expedition backpack (70–90 L) — with Small / Medium / Large tiers, harness, hip belt and stowed bundles

**ASSET NAME** — `Backpack` (one model per tier: `Backpack_Small`, `Backpack_Medium`, `Backpack_Large`, `Backpack_Expedition`), plus `Harness`, `HipBelt`, `RopeCoil`, `TarpRoll` and `WoodBundle`.

**REAL-WORLD REFERENCE** — An 85 L top-loading internal-frame expedition pack. It has a HDPE framesheet with two 6061 aluminium stays, a floating lid, a drawcord-closed extension collar (the "throat"), side compression straps, twin ice-axe loops with shaft keepers, a daisy chain, a padded harness with load lifters and a sternum strap, and a padded hip belt with a 50 mm buckle. The body is 210D–420D PU-coated nylon ripstop; the base is 1000D nylon. No brand, no logo patch, no printed text.

**GAME PURPOSE** — Inventory capacity (ItemDefs: Small 10 slots / 12 kg, Medium 14 / 18, Large 18 / 25, Expedition 24 / 32) and a visible statement of how much the player is carrying. It also displays the stowed ice axe, rope, tarp and wood.

**PLAYER SCALE** — Expedition: the lid rises 0.5 studs above the shoulder line and the base reaches the top of the LowerTorso. From behind it covers 92% of torso width.

**APPROXIMATE DIMENSIONS** — Real Expedition body (without lid): 0.82 m H × 0.36 m W × 0.30 m D ≈ 88 L.
@0.28: 2.93 × 1.29 × 1.07 studs. @0.35: 2.34 × 1.03 × 0.86 studs.
**Target = greybox `PACK_DIMENSIONS`** (H × W × D, extra height above shoulders, hip belt):

| Tier | Real volume | Target H × W × D (studs) | Lift | Hip belt |
|---|---|---|---|---|
| Small (Daypack) | 25–30 L | 1.45 × 1.45 × 0.70 | 0.00 | no |
| Medium (Alpine) | 40–45 L | 1.85 × 1.60 × 0.85 | 0.15 | yes |
| Large (Mountaineering) | 55–65 L | 2.15 × 1.72 × 1.00 | 0.30 | yes |
| Expedition | 85 L | 2.45 × 1.85 × 1.15 | 0.50 | yes |

Width is deliberately wider than the converted value because the R15 torso is 2 studs wide (rule 1.1-3).

**SILHOUETTE** — From the side: a tall wedge, deepest at mid-back and tapering 8% at the top (the code's `UpperBody` is 0.92 W × 0.92 D) toward the lid, with the lid overhanging the outer face by 0.04 D. From behind: a rounded rectangle with a domed lid, side pockets bulging out at the lower third, and the base slightly wider (+0.02 studs) than the body because of the abrasion panel. The back panel is flat against the torso and never bulges into the body.

**PRIMARY COMPONENTS**
- `Body` (PrimaryPart): main bag from the base seam up to the throat. Its outer face is gently convex (8–12% bulge at the centre; packed fabric is never flat). The back panel is flat with a foam pad of 2 vertical channels.
- `UpperBody`: tapered upper section and extension collar. Drawcord channel at the top edge; the cord lock sits under the lid.
- `Lid`: floating lid. A zipped pocket shell over a thin foam-free volume, domed 0.05 studs at its centre. It connects to the body by two rear webbing straps (from lid back corners to ladder-locks on the back-panel top) and two front lid straps.
- `BasePanel`: 1000D abrasion panel wrapping the bottom and the lowest 12% of the walls.
- Back panel with framesheet. The 2 stays show as two vertical ridges 0.35 studs apart, under the fabric only.

**SECONDARY COMPONENTS**
- `SidePocket` ×2: stretch-mesh pockets on the lower 32% of each side. Elastic binding at the top edge; the pocket bulges 0.07–0.14 studs.
- `CompressionStrap` ×4 (2 per side, at body heights +0.12h and −0.08h from the pack centre `cy`). Each 20 mm strap runs from a bar-tack at the back-panel edge across the side to a side-release buckle at the front edge, and passes **over** the side pocket.
- `DaisyChain`: 25 mm webbing on the outer face, bar-tacked every 0.12 studs to form loops. Runs from 0.2h above the base to 0.25h below the lid.
- `AxeLoop` ×2: 25 mm webbing loops at the outer-face base, at x = ±0.22 w (see 6.1). Each loop is sewn into the base-panel seam.
- Shaft keepers ×2: a 15 mm webbing tab with a hook-and-loop closure, 1.1–1.2 studs above each axe loop.
- `HaulLoop`: 25 mm webbing loop at the top of the back panel, bar-tacked at both ends.
- `LidStraps` ×2 (x = ±0.28 w), each ending in a `LidBuckle`. See ATTACHMENT POINTS for the two strap states.
- Base lash straps ×2 (x = ±0.45). They hang from ladder-locks on the base panel's front edge and wrap the `TarpRoll` when it is present (see bundles below).
- Load lifters ×2 (Medium, Large and Expedition only): 20 mm webbing from the framesheet's top corners down and forward to a ladder-lock on the top of each shoulder strap.

**MECHANICAL COMPONENTS** — Lid zip: #8 coil with a pull (`LidZip`, `ZipPull`), following the lid's front curve with end stops at both ends. Drawcord with a spring cord lock on the throat. Side-release buckles (male on the strap, female bar-tacked to the pack). Ladder-locks on every adjustable strap, with excess webbing folded and held by an elastic keeper. The tails never float.

**MATERIALS** — Body and lid: 210D nylon ripstop, PU coated. Base: 1000D nylon. Side pockets: polyester stretch mesh with a diamond knit. Webbing: nylon. Buckles and ladder-locks: acetal. Zip: nylon coil with an acetal pull and a cord tab. Back pad: perforated EVA foam under 3D spacer mesh.

**MATERIAL ROUGHNESS** — Ripstop 0.60 (0.50 where pack straps polish it; 0.75 on dusty base). Base 0.80. Mesh 0.85. Webbing 0.70. Buckles 0.40 (worn edges 0.30). Spacer mesh 0.90.

**SURFACE DETAILS** — Ripstop grid (normal only; ≈ 7 px pitch). Fabric tension wrinkles: radiating from each strap bar-tack, horizontal compression folds under each compression strap, and slack folds at the throat. Foam channels on the back panel. Mesh pocket holes in the alpha-free normal map with the dark interior shown through albedo. No embossed logos and no reflective print.

**STITCHING** — Single-needle lockstitch at 8 stitches per inch on panel seams, rendered as a 1-px-wide, 0.45-opacity normal-and-albedo line, 0.04 studs inside each seam. Bar-tacks (dense zigzag, 0.06 × 0.015 studs) at every webbing termination. Box-X stitch on the haul loop and on the shoulder-strap roots.

**SEAMS** — Bound seams on the internal edges (not visible). Visible seams: the body-to-base panel seam (horizontal, 0.12h above the base), the lid perimeter piping, the side-panel-to-front seams (vertical, at the front edges), the throat seam, and the pocket binding. Each seam shows a 0.02-stud raised welt in the normal map, a 3–5% darker albedo line and dirt collected in the seam.

**FASTENERS** — Every buckle joins exactly two pieces of webbing: a male end on the adjustable strap, and a female end bar-tacked to a fixed tab. Each lid strap runs from a bar-tack inside the lid's front edge, down the outer face, into a ladder-lock on the male buckle, which clips into the female buckle sewn to the body at 0.23h below the lid. The sternum and hip buckles are in the harness and belt.

**WEAR** — The base panel's front and back edges are scuffed lighter (+8% value, roughness +0.1). Shoulder-strap roots and the haul loop show fuzzed nylon (lighter fibres in albedo). Buckle edges are polished. The lid's front edge is faded 5% from sun. Ripstop is pilled where the axe shaft rubs: a vertical strip under the Axe anchor.

**SCRATCHES** — Few, because nylon does not scratch like metal. Show 3–6 short abrasion drags (fibres raised, lighter) on the base, and two scuffs where the axe adze sits against the outer face.

**DIRT** — Gravity and contact driven: the darkest band is on the bottom 15% (grey-brown, multiply 0.75), it fades upward with a ragged edge, and it collects in seams and under strap edges. Sweat darkening on the back panel's spacer mesh at the lumbar and shoulder-blade areas. The top of the lid is cleanest.

**MUD** — Optional variant mask: splash dots and smears on the base and the lower 10% of the outer face, with a dried-mud edge (lighter ring). The mud's albedo is not tinted by the item colour.

**SNOW** — `SnowCap`: a separate MeshPart that lies on the lid's domed top. It covers 0.9 w × 0.95 d of the lid and is 0.03–0.07 studs thick (deepest at the centre, feathered to zero at the edges). Its outer edge follows the lid's curvature so it never hangs past the lid. It sits 0.005 studs proud of the lid surface to prevent z-fighting, and its underside matches the lid's top surface. In Snowline+ zones, use the static baked snow overlay variant: snow packed into the lid-strap channels and the top of the side-pocket rims.

**WATER RESPONSE** — Driven by code (35% darker at full wetness on `Body`, `UpperBody` and `Lid`). Art provides a wet variant of the roughness map (ripstop 0.35, webbing 0.45) to swap in when wetness ≥ 0.6 (see 5.3). Webbing, mesh and the base panel are not darkened by code today. The art bakes them 10% darker in the wet variant, so their darkening stays consistent with the code-darkened panels.

**DAMAGE** — None in gameplay today. If needed later: a frayed hole in the base-panel corner with exposed lining, and a broken side-release buckle with one prong missing (its strap tail hangs and is still threaded through the ladder-lock).

**ATTACHMENT POINTS** (code contract — names and positions are fixed)
- Model `Backpack`, PrimaryPart `Body`. The code welds the PrimaryPart to UpperTorso at `UpperTorso.CFrame × (0, 0, Size.Z/2)` (pack space).
- Parts the code finds by name: `Body`, `UpperBody` and `Lid` get wetness darkening (searched with `GetDescendants`). `SnowCap` must be a **direct child** of the model (`FindFirstChild`).
- Anchors returned by `AssetFactory.backpack` (pack space). Here cy = lift + 0.8 − h/2 and lidY = cy + h/2:
  - `Axe` = (0.22 w, cy − 0.42 h + 1.6, d + 0.12), rotated 180° about Z (head down). The axe's grip origin is 1.6 studs from its head centre, so **the axe head centre lands at (0.22 w, cy − 0.42 h, d + 0.12): the axe loop must wrap exactly there.**
  - `Rope` = (0, lidY − 0.14 h, d + 0.12): coil under the lid straps on the outer face.
  - `Tarp` = (0, cy − 0.5 h − 0.17, 0.5 d): roll under the base, with its top tangent to the base panel.
  - `Wood` = (w/2 + 0.2, cy − 0.05 h, 0.5 d): vertical logs against the right side.

  | Tier | Axe head (x, y, z) | Rope (y, z) | Tarp (y, z) | Wood (x, y, z) | Pack bottom y |
  |---|---|---|---|---|---|
  | Small | 0.32, −0.53, 0.82 | 0.60, 0.82 | −0.82, 0.35 | 0.93, 0.00, 0.35 | −0.66 |
  | Medium | 0.35, −0.75, 0.97 | 0.69, 0.97 | −1.07, 0.43 | 1.00, −0.07, 0.43 | −0.92 |
  | Large | 0.38, −0.88, 1.12 | 0.80, 1.12 | −1.22, 0.50 | 1.06, −0.08, 0.50 | −1.07 |
  | Expedition | 0.41, −0.95, 1.27 | 0.96, 1.27 | −1.32, 0.58 | 1.13, −0.05, 0.58 | −1.18 |

- **Two lid-strap states.** A strap cannot float over a missing rope coil, and it cannot pass through a present one. Ship `LidStraps_Flat` (the straps lie on the outer face) and `LidStraps_OverCoil` (the straps arch 0.12–0.2 studs out over the coil's outer face, then return to the buckles). The code toggles their Transparency with the rope's stowed state (follow-up 6.2).
- **Harness** (`Harness` model, PrimaryPart `HarnessRoot`, invisible, at the UpperTorso centre). Parts: `ShoulderPad` ×2 (x = ±0.48, over the shoulder at y = 0.85, z spanning ±0.56), `ChestStrap` ×2 (0.30 wide, 1.0 tall, centred at y = 0.32, z = −0.55), `StrapTail` ×2 (lower webbing from the chest-strap bottom, wrapping to the pack's lower side corners), `SternumStrap` (y = 0.20, z = −0.61) and `SternumBuckle` (z = −0.64). Junction rule: each shoulder pad's rear end inserts 0.05–0.10 studs **into** the pack back panel at the yoke (pack space y ≈ 0.75–0.85, x = ±0.48), so no light shows between them. The sternum strap slides on a rail sewn to each chest strap, and the buckle joins the left half to the right half.
- **Hip belt** (`HipBelt`, PrimaryPart `BeltRoot`; mounted on LowerTorso for Medium, Large and Expedition). Parts: `HipWing` ×2 (padded wings on the LowerTorso sides), `BeltWebbing` (50 mm across the front) and `BeltBuckle` (50 mm side-release, centred at the front). The LowerTorso and UpperTorso rotate independently at the waist, so each hip wing's rear end extends 0.10–0.15 studs under the pack's lumbar pad. At ±15° of waist rotation no gap opens.
- **Stowed bundles** (each model's PrimaryPart sits at its anchor):
  - `RopeCoil`: see 2.3.
  - `TarpRoll` (PrimaryPart `Roll`): a 1.40-stud cylinder (axis X), Ø 0.34. Two `Strap` bands at x = ±0.45 are the pack's base lash straps: each wraps the roll and rises to its ladder-lock on the base panel's front edge.
  - `WoodBundle` (PrimaryPart `BundleRoot`): 1–3 split or round logs (1.4 studs long, Ø 0.19–0.25), vertical, spaced 0.24 studs along Z. Bark on the round faces; the split faces show the fresh-wood colour from `ATLAS_Wood_Bark`. Two `Strap` bands must be at the pack's side compression-strap heights (pack-relative +0.17 h and −0.03 h from the Wood anchor), and each strap buckles into the pack's own compression buckle. Today they sit at ±0.35 (follow-up 6.3). Logs press 0.02–0.05 studs into the side-pocket mesh, so the mesh shows compression rather than a gap.

**ANIMATION** — None (rigid, welded). Do not add bones: the pack rides UpperTorso, and torso motion is enough. The lid straps' tail ends must stay short (≤ 0.08 studs past the ladder-lock) and be tucked into elastic keepers, because no secondary motion exists to sell a dangling strap.

**PLAYER INTERACTION** — The pack is equipped through inventory. It is rebuilt whenever the loadout signature changes (pack id, held item, worn slots, axe/rope/tarp/wood stowed state). There are no prompts on the pack itself.

**GAMEPLAY FUNCTION** — Capacity and weight limit per tier. The visual size must make the tier obvious at 50 studs: the Expedition lid shows above the head outline from the side, while the Small pack is hidden behind the shoulders from the front.

**COLLISION** — None. Every part is `CanCollide = false`, `CanQuery = false`, `CanTouch = false` and `Massless = true` (already applied by `AssetFactory.weldCosmetic`). Use `CollisionFidelity = Box` to keep physics data minimal.

**LOD** — Expedition: LOD0 5,000 / LOD1 2,200 / LOD2 600 tris. Large: 4,500 / 2,000 / 550. Medium: 4,000 / 1,800 / 500. Small: 3,000 / 1,300 / 400. Harness: 1,200 / 500 / 150. Hip belt: 800 / 350 / 100. Bundles: rope 1,500 / 600 / 150, tarp roll 500 / 200 / 60, wood bundle 600 / 250 / 80 (at 3 logs).
- LOD1 removes stitch geometry, buckle cut-outs, the daisy-chain loops (texture only) and the zip-pull separation.
- LOD2 is the silhouette only: body, lid and pockets in one closed hull, with the straps baked into texture.

**TEXTURE STRATEGY** — One 1024² SurfaceAppearance per tier body (ColorMap with alpha for tint, NormalMap, RoughnessMap, MetalnessMap all black). Webbing, buckles, zip and loops are UV-mapped onto `TRIM_Webbing_Hardware`. The harness and hip belt share one 1024² map (padding, spacer mesh, webbing). All four tiers share the same base-panel and mesh texel areas (identical UV islands), so dirt reads the same across tiers.

**ROBLOX OPTIMIZATION** — Merge non-named parts into as few MeshParts as the code contract allows. Required separate parts: `Body`, `UpperBody`, `Lid`, `SnowCap`, `LidStraps_Flat` and `LidStraps_OverCoil`. Everything else (pockets, straps, loops, base panel, zip) merges into `Body` or `Lid`. Buckles, zip pulls and loops: `CastShadow = false`. Clone templates from storage; do not build the parts at runtime (see 5.1).

**FINAL VISUAL TARGET** — At 3 studs in third person, you can name every strap's start and end point, the zip line follows the lid's curve to its end stops, and the base is visibly dirtier than the lid. At 30 studs the tier is identifiable from silhouette and the tint reads as the item colour. Under wetness it reads as darker, slicker nylon, not as a different colour.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no oversize buckles (50 mm max, i.e. ≤ 0.18 studs) and no puffy pillow shapes. No floating components: no straps standing off the fabric, no buckle without both webbing ends. No impossible straps: no strap ending in mid-air, passing through the body, or running over an opening that it would block. No random decorative parts: no extra pockets, rings or carabiners hung for "detail". No excessive geometry: stitches are texture, not mesh. No perfectly clean surfaces. No generic low-poly look: no faceted cylinders on visible curved edges (lid perimeter ≥ 24 segments at LOD0). No disconnected components. No logos or text. No unrealistic materials: no glossy plastic-looking fabric, and no metallic fabric.

---

### 2.2 Ice axe

**ASSET NAME** — `IceAxe`.

**REAL-WORLD REFERENCE** — A classic mountaineering axe, 70 cm. Straight 7075 aluminium shaft of oval section (≈ 30 × 20 mm), anodised. Forged chromoly steel head: a 16 cm classic-curve pick with 5–6 teeth on the underside of the outer half, and a 6.5 cm-wide adze angled 8° down. Two steel rivets through the head and shaft. A carabiner hole in the head and a second hole below it for a leash. A rubber over-mould on the lower third. A steel spike with a collar, pressed and pinned into the shaft. Rated B-type (basic).

**GAME PURPOSE** — Item `ice_axe`. It is required for climbing ICE terrain (`ClimbConfig.IceTool`). It is shown held in the right hand when equipped, and otherwise stowed on the pack when owned.

**PLAYER SCALE** — The overall length reaches from the hand to just below the hip when held by the head. On the pack it spans from the axe loop to roughly the lid line (higher on Small).

**APPROXIMATE DIMENSIONS** — Real 0.70 m × 0.27 m (pick tip to adze edge) × 0.03 m. @0.28: 2.50 × 0.96 × 0.11 studs. @0.35: 2.00 × 0.77 × 0.09 studs.
**Target (greybox):** overall 2.36 studs (spike tip y = −0.65 to head top y = +1.71). Head pick-to-adze 1.08 studs (z = −0.68 to +0.40). Shaft section 0.13 (X) × 0.17 (Z) studs, a 1.4× exaggeration for the R15 hand.

**SILHOUETTE** — From the side: a long straight shaft, a T-head with the pick drooping downward (−6° at the root, −16° at the tip), and the adze slightly down-angled on the opposite side. The negative space between the pick and the shaft must stay open: the pick's underside teeth are visible against the background.

**PRIMARY COMPONENTS** — `Shaft` (PrimaryPart): oval section, slightly tapered (5%) toward the spike. `Head`: a forged block that sleeves 0.2 studs **over** the shaft top, with the pick and adze forged as one piece with it (not separate plates). `Spike`: a tapered point with a `SpikeCollar` overlapping the shaft bottom by 0.05 studs.

**SECONDARY COMPONENTS** — `Grip`: rubber over-mould on y −0.245…+0.305, with a raised finger ridge at the bottom edge and a 0.01-stud step down to the shaft at the top. `Rivet` ×2: domed heads on both faces of the head at y = 1.55 and 1.65, peened (slightly mushroomed) on the rear face. `LeashRing`: a steel ring through the head's lower hole at y = 1.30. `Leash`: see ANIMATION.

**MECHANICAL COMPONENTS** — The leash slider: a webbing loop through the ring, running down the shaft to a plastic slider that clamps the shaft at the grip's top edge. There are no moving parts in game.

**MATERIALS** — Shaft: anodised aluminium (ItemDefs tint 70, 110, 170). Head and spike: forged steel. Grip: rubber. Rivets: steel. Leash: 20 mm nylon webbing (200, 60, 40) with a black acetal slider.

**MATERIAL ROUGHNESS** — Anodise 0.35 (0.22 on worn high points). Steel 0.45 overall; the pick's teeth and tip edge are filed bright at 0.20; the adze back is 0.55 with forge scale. Rubber 0.85. Webbing 0.70.

**SURFACE DETAILS** — Forging parting line along the head's top (a 0.005-stud ridge in the normal map). Filed bevels on the pick tip and teeth. Hammer-flat adze face with the bevel ground on its underside only. Knurled texture on the grip (diamond pattern ≈ 0.02-stud pitch, normal only). Shaft: drilled hole at the leash ring position. No printed text, no length markings, no logos.

**STITCHING** — The leash webbing has one bar-tack at the ring loop and one at the slider.

**SEAMS** — Shaft-to-head joint: a visible 0.01-stud gap line around the head sleeve. Spike collar joint: the same. Grip over-mould edges.

**FASTENERS** — Two rivets through the head and shaft. One pin through the spike collar (a 0.02-stud dot on both sides).

**WEAR** — The anodise is worn to bare aluminium (albedo 180, roughness 0.25) on the shaft where it rests in the axe loop and on the front face just above the grip. The pick tip is bright steel. The spike tip is rounded and bright.

**SCRATCHES** — Longitudinal scratches on the shaft's lower half (from rock), 10–20 lines, 0.3–1.0 studs long, mostly vertical. Short, chaotic scratches on the pick's sides. The adze edge has 2–3 small chips.

**DIRT** — Grit packed between the pick's teeth and in the grip knurl. Faint rust bloom (non-metal, albedo 110, 60, 35; roughness 0.85) where the rivets meet the head, and at the spike collar.

**MUD** — Optional: dried mud on the bottom 0.3 studs of the spike and collar only.

**SNOW** — The axe is held or stowed on the pack, so it carries no snow cap. In the static ice-climb variant, rime fills the pick teeth (white, roughness 0.9).

**WATER RESPONSE** — Metal does not darken. When the player is wet ≥ 0.6, the wet roughness variant drops the anodise to 0.20 and the rubber to 0.60. Webbing darkens 30%.

**DAMAGE** — None in game today. If added later: a bent pick (the tip bent 10° sideways), never a snapped shaft.

**ATTACHMENT POINTS** (code contract) — Mesh origin = **grip origin** (0, 0, 0), the centre of the closed hand on the grip. +Y runs along the shaft toward the head, and **the head centre is at +1.6 studs**: the pack's `Axe` anchor depends on this exact distance. The pick points −Z and the adze +Z.
- Held: `RightHand.CFrame × (0, −0.3 × hand.Size.Y, 0) × Angles(−90°, 0, 0)`. The shaft points forward from the hand, head forward.
- Stowed: the pack's `Axe` anchor rotates it 180° about Z, so the head is down in the axe loop and the spike is up.

**ANIMATION** — No bones. **The leash must not be modelled hanging**, because a static hanging leash points the wrong way when stowed upside down. Model it laid flat along the shaft from the `LeashRing` to the slider clamped at the grip top. That reads correctly in both orientations.

**PLAYER INTERACTION** — Equipped from the hotbar. The swing and climb animations belong to the character (not this asset). The grip origin must stay at the hand's centre so the climb animations do not show the hand sliding off the grip.

**GAMEPLAY FUNCTION** — Gate for ice climbing. Readable as an "axe" at 40 studs, so the pick-and-adze T-head silhouette must be legible.

**COLLISION** — None (cosmetic weld: Massless, CanCollide, CanQuery and CanTouch all false). `CollisionFidelity = Box`.

**LOD** — LOD0 2,500 / LOD1 900 / LOD2 200 tris. LOD1 drops the teeth (texture only), the rivet domes and the grip ridges. LOD2 is a shaft prism plus a T-head.

**TEXTURE STRATEGY** — UV the head, spike, rivets and shaft onto `ATLAS_Metal`. Reserve a 256 × 256 region of a 512² unique map for the wear masks of the shaft and grip. Leash on `TRIM_Webbing_Hardware`.

**ROBLOX OPTIMIZATION** — One MeshPart for metal and rubber (one SurfaceAppearance). The leash is a second MeshPart only if it needs a different SurfaceAppearance; otherwise merge it. `RenderFidelity = Automatic`.

**FINAL VISUAL TARGET** — Up close you see that the head is one forged piece riveted through the shaft, the teeth are on the pick's underside, and the shaft is worn bright where it lives in the axe loop. At 40 studs it reads as a steel T on a blue stick.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no fat pick, no oversized adze (adze width ≤ 0.30 studs). No floating components: the head must sleeve the shaft, not sit on top of it. No impossible straps: no leash looping off into space. No random decorative parts: no extra holes, no spikes on the adze. No excessive geometry: teeth go in the normal map at LOD1+. No perfectly clean surfaces. No generic low-poly look: the shaft is ≥ 10-sided oval at LOD0. No disconnected components. No logos or text. No unrealistic materials: no chrome mirror finish, and the pick is not anodised.

---

### 2.3 Dynamic climbing rope — coiled and deployed

**ASSET NAME** — `RopeCoil` (stowed or carried) and `RopeLine` (deployed: a Beam or segment set; not built in code yet).

**REAL-WORLD REFERENCE** — A 60 m single dynamic rope, Ø 9.8 mm, kernmantle construction: a braided polyester sheath (32 carriers, giving a visible diagonal herringbone) over a nylon core. Factory middle mark (a black sheath section). Ends heat-sealed and whipped with tape. Carried as a mountaineer's coil, with the coil wrapped 4–5 times by the rope's end and secured through the coil's top.

**GAME PURPOSE** — Item `rope`. It is shown stowed under the pack's lid straps when owned. It is consumed to re-tension tarp guy lines ("Reinforce (1 rope)"). The deployed form is for future fixed lines and rescue.

**PLAYER SCALE** — The coil is 60% as wide as the Expedition pack and fits within the lid-strap spacing on all tiers.

**APPROXIMATE DIMENSIONS** — Real coil ≈ 0.40 m wide × 0.22 m tall × 0.07 m thick. @0.28: 1.43 × 0.79 × 0.25 studs. @0.35: 1.14 × 0.63 × 0.20 studs.
**Target: 1.15 × 0.62 × 0.22 studs.** The greybox is 0.84 wide, which is narrower than the lid-strap spacing (follow-up 6.2). Rope diameter is 0.065 studs, a 2× exaggeration (real ≈ 0.03 studs).

**SILHOUETTE** — A flattened oval ring of many parallel strands, with a tight vertical band of 4–5 wraps (the `Whipping`) at the top centre. The free end tucks through the top of the coil and protrudes 0.1 studs. The strands in the coil's lower curve hang 3–5% lower than those at the top (gravity sag of each loop).

**PRIMARY COMPONENTS** — The coil bundle. Model 12–16 visible outer strands as individual tubes along the outer and visible faces. The interior volume is a single swept hull with a strand normal map (no hidden interior strands).

**SECONDARY COMPONENTS** — `Whipping`: 4–5 tight wraps of the same rope around the bundle at the top, plus the tucked end. A middle-mark section: a 0.15-stud black sheath segment visible on one strand.

**MECHANICAL COMPONENTS** — None.

**MATERIALS** — Polyester sheath (ItemDefs 220, 110, 40) with a secondary tracer colour (black or blue, 2 of the 32 carriers) to make the braid read.

**MATERIAL ROUGHNESS** — 0.75 for a new rope; 0.85 for a fuzzed, used rope.

**SURFACE DETAILS** — Herringbone braid normal at ≈ 0.04-stud pitch along the strand, with the tracer colour spiralling. Fuzz (a lighter albedo halo) on the outermost strands.

**STITCHING** — None.

**SEAMS** — None. The rope ends are sealed: a 0.04-stud melted, slightly darker tip wrapped with tape.

**FASTENERS** — The coil secures itself (the wraps plus the tuck). On the pack it is held only by the lid straps (`LidStraps_OverCoil`).

**WEAR** — Sheath fuzz at 15–30% coverage. Glazed (roughness 0.6) short sections from rappel heat on 2–3 strands.

**SCRATCHES** — Not applicable (textile).

**DIRT** — Grey-brown grime in the strand gaps and on the coil's bottom curve. Darker in older ropes.

**MUD** — Optional: mud on the bottom curve of the coil only.

**SNOW** — None while stowed (it is under the lid straps, mostly vertical). When deployed on snow, the Beam texture has no snow; the terrain handles it.

**WATER RESPONSE** — Wet rope darkens 30% and sags more. The deployed Beam reduces CurveSize as the rope gets heavier. Not driven by code today.

**DAMAGE** — None now. Future: a core-shot section (white core visible through a torn sheath).

**ATTACHMENT POINTS** — `RopeCoil` PrimaryPart `CoilRoot` (invisible, at the coil centre). The coil lies in the XY plane, its outer face pointing +Z; the whipping is at +Y (y = +0.22 to +0.3). It mounts at the pack's `Rope` anchor. Deployed (proposed): Attachments `RopeStart` and `RopeEnd` on the anchoring parts (stakes, carabiners, pole tops).

**ANIMATION** — The coil has none. Deployed: a `Beam` between two Attachments, using a braid texture (1 tile = 0.25 studs of rope, `TextureMode = Wrap`), Width0 = Width1 = 0.065, and `CurveSize0/1` for slack sag. `FaceCamera = true`, so the flat ribbon always faces the viewer. Physical slack uses a hidden `RopeConstraint` (`Visible = false`) whose Length drives CurveSize. Do not build a chain of physical segments for cosmetics.

**PLAYER INTERACTION** — Through inventory (Reinforce prompt on the tarp shelter).

**GAMEPLAY FUNCTION** — Shelter repair; future climbing. The coil must be readable as rope (not a tyre or a ring) at 20 studs: that needs visible parallel strands and the whipping band.

**COLLISION** — The coil has none (cosmetic). Deployed rope: the Beam has no collision. If gameplay needs a hit target, use an invisible thin part with `CanQuery = true` and `CanCollide = false`.

**LOD** — Coil: LOD0 1,500 / LOD1 600 / LOD2 150 tris. LOD1 merges the outer strands into the hull, with the strand normal kept. LOD2 is an oval torus of 8 × 6 segments. The Beam has no LOD (engine sprite).

**TEXTURE STRATEGY** — 512² coil map (ColorMap, NormalMap, Roughness). The braid texture is 256 × 64 and tiles along the length. One rope texture serves the coil strands, the `RidgeLine` and `GuyLine` (with a different tint), and the Beam.

**ROBLOX OPTIMIZATION** — One MeshPart for the whole coil. The Beam costs no triangles but does cost overdraw; keep deployed ropes ≤ 20 visible at once.

**FINAL VISUAL TARGET** — A hand-coiled rope: strands parallel but not identical, slightly irregular loop lengths, wraps tight, end tucked. Deployed, it sags naturally between anchors and shows a braid when the camera is close.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no rope thicker than 0.08 studs. No floating components: the coil touches the pack face and both lid straps. No impossible straps: the lid straps pass over the coil, never through it. No random decorative parts: no extra knots or dangling ends. No excessive geometry: no 50 individual wraps. No perfectly clean surfaces. No generic low-poly look: no single smooth torus at LOD0. No disconnected components: the free end enters the coil. No logos or text. No unrealistic materials: no plastic tube shine.

---

### 2.4 Locking carabiner

**ASSET NAME** — `Carabiner` (not built in code yet; proposed).

**REAL-WORLD REFERENCE** — An HMS (pear-shaped) screw-gate locking carabiner: 11 cm × 7.5 cm, 11 mm I-beam bar stock, hot-forged aluminium with an anodised spine. Keylock nose (no hook notch). Solid gate on a pin hinge with an internal spring. Threaded locking sleeve (≈ 2.5 cm long) on the gate, with a red "unlocked" indicator band revealed when open.

**GAME PURPOSE** — Visual connector on the harness and hip belt; future rope anchoring. Gives the gear a credible clipping point.

**PLAYER SCALE** — About the length of the R15 hand.

**APPROXIMATE DIMENSIONS** — Real 0.110 × 0.075 × 0.011 m. @0.28: 0.39 × 0.27 × 0.04 studs. @0.35: 0.31 × 0.21 × 0.03 studs. **Target 0.36 × 0.25 × 0.045 studs** (bar stock exaggerated 1.3×).

**SILHOUETTE** — A pear: a wide basket end (the rope end) and a narrower spine end. Straight spine, curved gate side. The gate gap is closed. The locking sleeve is a visibly thicker section of the gate.

**PRIMARY COMPONENTS** — Frame (spine plus basket, one forged piece with an I-beam cross-section). Gate (a round bar, Ø 0.035 studs).

**SECONDARY COMPONENTS** — Locking sleeve. Hinge pin (rivet head visible on both faces). Keylock nose slot.

**MECHANICAL COMPONENTS** — The gate pivots on the hinge pin at the spine end. The sleeve threads along the gate. For a future open animation: the gate rotates 30° inward around the pin axis, and the sleeve slides 0.06 studs toward the hinge first.

**MATERIALS** — Anodised aluminium frame (dark grey or blue, untinted by gameplay). Bare aluminium gate. Sleeve: anodised aluminium; red anodised indicator band under it.

**MATERIAL ROUGHNESS** — Anodise 0.35; rope-bearing surface (inner basket) polished 0.15; sleeve knurl 0.50.

**SURFACE DETAILS** — I-beam channel on the spine sides. Knurled sleeve. Forging flash line, faint. No laser-etched strength ratings or text.

**STITCHING** — None.

**SEAMS** — None. The gate-to-nose junction shows a 0.003-stud gap.

**FASTENERS** — The hinge pin (riveted).

**WEAR** — The anodise is worn to bare metal (albedo 185) on the inner basket curve where rope runs, and on the sleeve edges.

**SCRATCHES** — Dense fine scratches across the basket exterior (rock contact), random directions.

**DIRT** — Grit in the I-beam channel and the sleeve knurl.

**MUD** — No.

**SNOW** — No.

**WATER RESPONSE** — Roughness −0.1 when wet. No darkening.

**DAMAGE** — None.

**ATTACHMENT POINTS** (proposed) — Mesh origin at the basket's inner curve centre (where a rope or strap sits). Proposed anchors: `GearLoopL` / `GearLoopR` on the `HipBelt` wings (the carabiner hangs from a 10 mm gear loop that passes through its basket), and an anchor on the pack's `HaulLoop`. The loop must pass **through** the carabiner frame, not touch it from outside.

**ANIMATION** — Static; there is no swing. Gear-loop carabiners hang straight down from the loop (pre-posed).

**PLAYER INTERACTION** — None today.

**GAMEPLAY FUNCTION** — Visual credibility; a future anchor.

**COLLISION** — None (cosmetic). `CollisionFidelity = Box`. `CastShadow = false`.

**LOD** — LOD0 600 / LOD1 220 / LOD2 60 tris.

**TEXTURE STRATEGY** — Entirely on `ATLAS_Metal`; no unique map.

**ROBLOX OPTIMIZATION** — One MeshPart. Merge into the hip belt mesh if it never moves.

**FINAL VISUAL TARGET** — A clearly closed, locked HMS: the sleeve covers the gate's nose end and the frame has worn bare spots inside the basket.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no oversized, bubble-shaped frame. No floating components: it hangs from a real loop. No impossible straps: no webbing passing through a closed gate. No random decorative parts. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: the frame is ≥ 8 sides around and ≥ 24 segments around its length. No disconnected components. No logos or text. No unrealistic materials: no gold or chrome.

---

### 2.5 Crampons

**ASSET NAME** — `Crampons` (pair; not built in code yet; proposed).

**REAL-WORLD REFERENCE** — 12-point steel semi-automatic crampons. Each one has:
- two stamped and forged front-section and heel-section frames, joined by an adjustable flat steel centre bar (a row of holes plus a spring clip);
- 2 horizontal front points, 4 secondary points per front section, and 4 heel points;
- a wire toe bail (for boots with a toe welt), a hinged plastic heel lever with a wire heel bail, and a 20 mm nylon ankle strap with a buckle threaded through a ring on the front section;
- rubber anti-balling plates under the front and heel sections.

**GAME PURPOSE** — Future traction item for ice and steep snow. It also visually confirms the boots are B2/B3 rated.

**PLAYER SCALE** — It matches the boot sole outline exactly. The front points protrude 0.10 studs beyond the toe.

**APPROXIMATE DIMENSIONS** — Real 0.33 × 0.11 × 0.05 m (points add 0.035 m depth). @0.28: 1.18 × 0.39 × 0.18 studs. @0.35: 0.94 × 0.31 × 0.14 studs. **Target: boot `Sole` footprint (foot.X × 1.18 by foot.Z × 1.2), +0.10 studs at the front points; point length 0.11 studs below the sole.**

**SILHOUETTE** — From the side: a flat frame under the sole with a row of downward teeth, two forward-pointing front points, and a heel bail rising up the back of the heel. From below: two frame sections connected by a narrow bar.

**PRIMARY COMPONENTS** — Front frame with its points, heel frame with its points, centre bar.

**SECONDARY COMPONENTS** — Toe bail (Ø 0.02-stud wire), heel lever and bail, ankle strap with buckle, anti-balling plates.

**MECHANICAL COMPONENTS** — The centre bar slides through a slot in the heel frame, held by a spring clip at one hole. The heel lever pivots on a rivet. The toe bail pivots in two eyelets.

**MATERIALS** — Chromoly steel frames and points. Spring-steel bails. Glass-filled nylon heel lever (black). Nylon webbing strap. Rubber anti-balling plates (black or dark blue).

**MATERIAL ROUGHNESS** — Steel 0.45; point tips 0.25 (sharpened, bright); heel lever 0.45; rubber 0.85.

**SURFACE DETAILS** — Stamping edges with a slight roll-over; forged point taper; drilled adjustment holes; anti-balling plate ribs.

**STITCHING** — The ankle strap has a bar-tack where it loops through the front ring.

**SEAMS** — None.

**FASTENERS** — Heel-lever rivet, centre-bar spring clip, ankle-strap buckle (it joins the strap's two ends around the boot cuff).

**WEAR** — Points ground bright; frame paint or zinc plating worn off along the edges.

**SCRATCHES** — Heavy on the points and frame undersides; light on the top surfaces.

**DIRT** — Grit in the adjustment holes.

**MUD** — No (an alpine item).

**SNOW** — Packed snow on the top of the anti-balling plates and between the frame and the plate (white, roughness 0.9) in the "in use" variant.

**WATER RESPONSE** — Steel roughness −0.1 when wet; light rust bloom at the rivets in the aged variant.

**DAMAGE** — None.

**ATTACHMENT POINTS** (proposed) — Worn: weld to `LeftFoot` / `RightFoot` with the crampon top plane touching the bottom of the boot `Sole` part (foot.Y/2 + 0.08 below the foot centre). The toe bail must sit on the boot's toe welt, and the heel bail in the heel welt groove. Stowed: inside a crampon pouch strapped under the pack lid (a new pack anchor `Crampons`, proposed).

**ANIMATION** — None (rigid with the foot).

**PLAYER INTERACTION** — Future equip slot.

**GAMEPLAY FUNCTION** — Future: ice and snow traction.

**COLLISION** — None (cosmetic). The character's own collider handles footing.

**LOD** — LOD0 2,000 (pair) / LOD1 700 / LOD2 150 tris.

**TEXTURE STRATEGY** — `ATLAS_Metal` for steel; webbing on `TRIM_Webbing_Hardware`; a small unique 256² region for the plates.

**ROBLOX OPTIMIZATION** — One MeshPart per foot. `CastShadow = false` at LOD1+.

**FINAL VISUAL TARGET** — Clearly strapped onto the boot: the bail is on the welt, the strap wraps the cuff, and the points are bright-tipped and sharp.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no oversized spikes. No floating components: the crampon touches the sole along its whole length. No impossible straps: the ankle strap wraps the boot cuff, not air. No random decorative parts. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: the points are tapered, not cones. No disconnected components. No logos or text. No unrealistic materials.

---

### 2.6 Mountaineering boots

**ASSET NAME** — `Boots` (item `alpine_boots`). Code part names: `Boots_LeftFoot`, `Boots_RightFoot`, `Sole` ×2.

**REAL-WORLD REFERENCE** — A single-layer 2.6–3.0 mm full-grain leather mountaineering boot, B2 rated. It has:
- a rubber rand wrapping the toe and the lower 2 cm all round;
- a toe welt and a heel welt for semi-automatic crampons;
- a stiff midsole and a lugged rubber outsole with an 8 mm deep, 2–3 cm lug pattern and a defined heel breast;
- a padded scree collar, a gusseted tongue, lacing through 4 metal D-rings at the lower eyestays and 2 open lace hooks plus 1 locking hook at the ankle, with round 4 mm laces tied in a double knot.

**GAME PURPOSE** — Foot insulation (Feet 3.5). It distinguishes alpine boots from trail runners.

**PLAYER SCALE** — Covers the R15 foot and should rise 0.25–0.35 studs up the lower leg (a real 18 cm boot shaft). The code currently covers the foot only (follow-up 6.4).

**APPROXIMATE DIMENSIONS** — Real (EU 43) 0.31 m L × 0.12 m W × 0.19 m H. @0.28: 1.11 × 0.43 × 0.68 studs. @0.35: 0.89 × 0.34 × 0.54 studs. **Target: R15 foot part × 1.14 (shell), sole = foot.X × 1.18 × 0.12 tall × foot.Z × 1.20, plus the shaft extension above.**

**SILHOUETTE** — A rockered toe rising 0.06 studs off the ground, a defined heel breast notch, an upper that rises at the ankle with a slight forward lean, and a scree collar 10% wider than the leg.

**PRIMARY COMPONENTS** — Upper (vamp, quarters, tongue). `Sole` (outsole with lugs and midsole). Rand.

**SECONDARY COMPONENTS** — Lacing hardware, laces and knot, scree collar, heel pull loop (webbing, bar-tacked), toe and heel welts.

**MECHANICAL COMPONENTS** — The lacing system: the lace runs criss-cross through the D-rings, around the hooks, and ends in a knot whose 2 loops and 2 tails lie flat on the tongue (not dangling free).

**MATERIALS** — Waxed full-grain leather (ItemDefs 110, 40, 30), rubber rand (dark grey 40), rubber outsole (25, 22, 20), nylon laces, steel hooks (black powder-coat), padded nylon scree collar.

**MATERIAL ROUGHNESS** — Leather 0.50 on the toe (polished by rock), 0.65 elsewhere; rand 0.75; outsole 0.90; hooks 0.40.

**SURFACE DETAILS** — Leather grain (fine pebble normal); flex creases across the vamp (3–4 deep folds); the rand's moulded texture; lug pattern geometry on LOD0 (the sole is seen when stepping and climbing).

**STITCHING** — Double-row lockstitch where the quarters meet the vamp. Single row around the scree collar. Visible as raised thread lines on the leather.

**SEAMS** — Rear heel seam (vertical, covered by a leather strip), the vamp-to-quarter seams, and the rand's edge line (the rubber is glued, so it shows an edge, not stitches).

**FASTENERS** — Laces, D-rings, hooks.

**WEAR** — Toe leather scuffed through the wax (a lighter, matte patch); rand chipped at the toe; lug edges rounded on the heel's rear and the toe's tip.

**SCRATCHES** — On the leather toe and inner ankles (crampon nicks: 2–3 short cuts on the inner ankle, showing lighter suede).

**DIRT** — Darkest on the sole and rand, fading up the upper; dust in the flex creases; tide-line salt stains (a white wavy edge) 0.1 studs above the rand.

**MUD** — Mud variant: packed in the lugs and splashed onto the rand and the lower upper; the lighter, dried edges crack.

**SNOW** — Snow packed in the lugs (sole texture variant) and a light dusting on the toe top in Snowline+ zones.

**WATER RESPONSE** — Code darkens the shells 35%. The wet roughness variant drops waxed leather to 0.35. The rubber is unaffected.

**DAMAGE** — None in game.

**ATTACHMENT POINTS** (code contract) — Shells are welded to `LeftFoot` / `RightFoot`. The shell's origin is the foot part's centre, and its size is the foot size × 1.14. The `Sole` shell's centre is at (0, −foot.Y/2 − 0.02, 0) relative to the foot. Proposed: `CramponMount` (the sole's bottom plane) and boot cuff shells on `LeftLowerLeg` / `RightLowerLeg`. The pants hem overlaps that cuff by 0.08 studs (a gaiter style) so no skin shows at any knee bend.

**ANIMATION** — Rigid per foot. The R15 foot does not bend, so model the flex creases in their resting state.

**PLAYER INTERACTION** — Worn slot `Boots`.

**GAMEPLAY FUNCTION** — Feet insulation. Visually distinct from `trail_runners`, which have a low cut, a mesh upper (90, 160, 90), a foam midsole and shallow lugs.

**COLLISION** — None (cosmetic shells).

**LOD** — LOD0 3,000 (pair) / LOD1 1,200 / LOD2 300 tris. The lugs become normal-only at LOD1.

**TEXTURE STRATEGY** — One 1024² map for both boots (mirrored UVs are allowed, except on the dirt and wear masks, which use an overlay detail island so left and right differ). Laces and hooks on `TRIM_Webbing_Hardware`.

**ROBLOX OPTIMIZATION** — The upper and sole merge into one MeshPart per foot if the code is updated to stop creating a separate `Sole` part; otherwise keep 2 per foot and match the names.

**FINAL VISUAL TARGET** — A heavy, stiff leather boot with a rubber rand, a deep-lug sole and a gaiter-like scree collar. Dirt and scuffs are concentrated where it touches rock and snow.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no clown-boot length (≤ 1.2 × foot length). No floating components: no laces hovering off the tongue. No impossible straps. No random decorative parts: no buckles that do nothing. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: the sole lug edges are bevelled. No disconnected components: the sole contacts the upper all round. No logos or text. No unrealistic materials: no glossy patent-leather look.

---

### 2.7 Insulated parka — with clothing family notes

**ASSET NAME** — `InsulatedParka` (item `insulated_parka`). Code part names: `Jacket_UpperTorso`, `Jacket_LowerTorso`, `Jacket_LeftUpperArm`, `Jacket_RightUpperArm`, `Jacket_LeftLowerArm`, `Jacket_RightLowerArm`, `JacketZip`, `ChestPocket`, `Hood`.

**REAL-WORLD REFERENCE** — An expedition down parka.
- Layered construction, from the inside out: a 20D nylon liner; 800-fill goose down in box-wall baffles; a 20D nylon ripstop shell with a durable water-repellent finish.
- Horizontal baffles 10–12 cm apart on the torso and 8–10 cm on the sleeves.
- A two-way #8 coil centre-front zip under an internal and an external storm flap with hook-and-loop tabs.
- A chest pocket with a vertical zip.
- An insulated hood with a stiffened brim and a rear volume adjuster; when down, it bunches behind the neck.
- Elastic-bound cuffs with hook-and-loop tabs, a drawcord hem with cord locks, and reinforced 40D shoulder panels (pack-strap abrasion).

**GAME PURPOSE** — The highest torso insulation (Torso 6, Head 1). Head insulation > 0 triggers the `Hood` part (`EquipmentService.build`).

**PLAYER SCALE** — Shell scale 1.10 over each covered body part, so the parka reads visibly bulky: 10% larger than the body all round.

**APPROXIMATE DIMENSIONS** — Real (size L) body length 0.80 m, chest 1.30 m circumference, loft 4–5 cm. @0.28 the loft is 0.16 studs; @0.35 it is 0.13 studs. **Target: each shell = body part × 1.10** (≈ 0.1 studs of loft on the 1-stud torso depth; within the band).

**SILHOUETTE** — A puffy torso with scalloped side edges: each baffle bulges 0.02–0.03 studs and pinches between baffles. Sleeves bulkier than the arms. The hood is a soft bunched roll behind the neck. The hem falls below the LowerTorso.

**PRIMARY COMPONENTS** — Body shells per R15 part (torso front and back panels, sleeves). `Hood`.

**SECONDARY COMPONENTS** — `JacketZip` with the storm flap. `ChestPocket` on the wearer's left chest (−X), zip vertical. Shoulder reinforcement panels. Cuffs. Hem drawcord.

**MECHANICAL COMPONENTS** — The two-way zip: two sliders, both with cord pulls, the top slider at the collar and the bottom at the hem. Cord locks at the hem sides (flat against the fabric, not dangling).

**MATERIALS** — 20D ripstop shell (ItemDefs 200, 70, 40); 40D reinforcement panels in a 10%-darker matching tint; liner (dark grey, visible only at the cuffs and the hood opening); coil zip; acetal pulls.

**MATERIAL ROUGHNESS** — Shell 0.45. Thin nylon has a soft sheen, so the baffle crests sit at 0.40 and the valleys at 0.55. Reinforcement panels 0.60.

**SURFACE DETAILS** — Baffle bulges in the geometry (LOD0) and normal. Compression creases at the elbows and armpits. A ripstop grid normal. Down quills poking through at 2–3 places (tiny white specks in the albedo). No logos, no reflective prints.

**STITCHING** — Baffle lines sewn through at the seam valleys (a single row each). Topstitching along the zip flap (two parallel rows, 0.03 studs apart). Bar-tacks at the pocket ends.

**SEAMS** — Shoulder seam (offset forward of the strap path), side seams, raglan or set-in sleeve seams (choose set-in: R15's separate arm parts make the seam line fall at the shoulder joint, which hides the segment break), and the cuff binding.

**FASTENERS** — Centre zip, hook-and-loop storm-flap tabs (3 rectangles of slightly different texture), and the pocket zip.

**WEAR** — Pilled and darker reinforcement panels where the harness `ShoulderPad` sits. Shiny worn cuff ends. A 5% sun-faded hood top.

**SCRATCHES** — Not applicable. Use 1–2 small repair patches instead (a rectangle with rounded corners, stitched, in a matching colour) on the forearm.

**DIRT** — Grime on the cuffs, the lower front hem and the zip line. Light soot spots on the forearms (campfire). Sweat lines inside the collar.

**MUD** — Light splashes on the lower sleeves only.

**SNOW** — Snow is not shown on clothing shells today (the code has no clothing snow). Do not bake snow into the base map. A possible future overlay: shoulders and hood top.

**WATER RESPONSE** — Code darkening of 35%. The wet roughness variant takes the shell to 0.30. A soaked down parka also loses loft, but geometry cannot change at runtime, so do not try. The darkening plus lower roughness is the signal.

**DAMAGE** — Future: a burn hole with feathers escaping (campfire proximity).

**ATTACHMENT POINTS** (code contract) — Each shell is welded to its body part, with its centre at the body part's centre and its size = part size × 1.10. `JacketZip` is at UpperTorso (0.08, 0, −Z/2 − 0.01) on the 1.1× shell; the storm flap is centred so its edge covers the zip at +0.08 X. `ChestPocket` is at (−0.22 X, +0.20 Y) on the front face. `Hood` is at (0, Y/2 − 0.05, Z/2 − 0.05), size (0.55 X, 0.45, 0.5). Shell overlaps at the joints: each sleeve shell extends 0.06 studs into the next segment's shell so no gap opens at R15 joint bends of up to 90°.

**ANIMATION** — Rigid per body part (R15 segments). Fake drape with the creases. Layered clothing (WrapLayer) is an option for a later pass (see 5.6).

**PLAYER INTERACTION** — Worn slot `Jacket`. When worn, the base layer is hidden (code).

**GAMEPLAY FUNCTION** — Torso and head insulation; strong wet penalty (down).

**COLLISION** — None (Massless shells, no collision, query or touch).

**LOD** — Full parka: LOD0 4,500 / LOD1 1,800 / LOD2 500 tris. Baffles are geometry at LOD0 and normal-only at LOD1+.

**TEXTURE STRATEGY** — One 1024² map for all parka shells. The zip, pulls and pocket zip are on `TRIM_Webbing_Hardware`. The fleece and hardshell use their own 1024² maps but share UV layouts with the parka (identical shell meshes per R15 part), so the dirt masks can be reused.

**ROBLOX OPTIMIZATION** — Shells must be per-body-part MeshParts to keep the code's weld scheme. Merge `JacketZip` and `ChestPocket` into `Jacket_UpperTorso` only if the code stops creating them (otherwise match the names).

**FINAL VISUAL TARGET** — A bulky, baffled down parka. The zip runs from the hem to the chin under a storm flap, the hood is bunched at the neck, the shoulders are scuffed by the pack straps and the cuffs are grimy.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: baffles ≤ 0.03 studs of bulge, not inflated tubes. No floating components: no zip not sewn to fabric. No impossible straps: no decorative straps across the chest. No random decorative parts: no epaulettes, no extra pockets. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: no single-box torso. No disconnected components: the shells overlap at the joints. No logos or text. No unrealistic materials: no wet-look vinyl.

**Clothing family notes** (same field logic as the parka; same shell scheme and code names `<Slot>_<BodyPart>`):

- **Fleece jacket** (`fleece_jacket`, 60, 120, 160; Torso 3; scale 1.10, no hood). 200-weight polyester fleece. Full-zip #5 coil with no storm flap, two hand pockets and a chest pocket (the code's `ChestPocket`). Flatlock seams (flat, zigzag-looking stitch), stretch-binding cuffs and hem. Roughness 0.95. Pilling at the underarms and side panels where the pack rubs. Wet: 35% darker (code), roughness unchanged (fleece stays matte). LOD0 3,000.
- **Hardshell jacket** (`shell_jacket`, 210, 170, 30; Torso 1.2, Head 0.5, so it has a hood). A 3-layer waterproof laminate with a smooth face fabric at roughness 0.50 and a crisp crease pattern (thin, sharp folds, unlike the parka's rounded ones). It has:
  - laminated water-resistant zips (coated tape, no visible coil teeth, roughness 0.30), and pit zips under the arms;
  - a helmet-compatible hood with a laminated brim;
  - welded hem and cuff tabs;
  - no visible stitching on the face. The seams are taped inside, and only a faint seam line shows on the outside.

  Wet: beading. Since droplets cannot be simulated, the wet roughness variant sets the face to 0.25 and adds a bead-dot normal pattern. LOD0 3,000.
- **Base layers** (`merino_base`, 70, 70, 90; `cotton_tee`, 200, 200, 200; scale 1.03). Shown only without a jacket.
  - Merino: fine jersey knit (normal at ≈ 0.01-stud pitch), flatlock seams, and a sleeve end with cover-stitched hem at the elbow: the code's `BaseLayer` slot covers only the UpperTorso, LowerTorso and UpperArms, so no forearm sleeve exists to carry a cuff.
  - Cotton tee: plain jersey, a ribbed collar, a hemmed sleeve end on the upper arm. Cotton shows **wet darkening worst**: its wet variant adds sweat patches at the underarms and chest (an extra 10% darker region), because cotton holds water.
  - LOD0 1,500.
- **Gloves** (`liner_gloves`, 50, 50, 50, scale 1.12; `insulated_gloves`, 30, 30, 35).
  - Liner: stretch fleece knit, silicone grip dots on the palm (normal plus a slightly different albedo), and a cuff that tucks under the sleeve.
  - Insulated: a goat-leather palm and finger fronts (roughness 0.55, worn shiny on the fingertips), a nylon back (roughness 0.6), a gauntlet cuff that goes **over** the sleeve shell (it overlaps the LowerArm shell by 0.1 studs), and a cuff cinch strap with a cord lock and a wrist leash loop sewn to the cuff (the leash itself is omitted).
  - R15 hands are single blocks, so model a relaxed half-fist shape, and keep the fingers as one mitt-like mass with finger separations in the normal only. LOD0 1,200 per pair.
- **Beanie** (`wool_beanie`, 150, 40, 40; head shell 1.05 × 0.45 × 1.05 at y = +0.32 × head height). 2×2 rib knit with a folded cuff (double thickness, 0.06 studs). Roughness 0.95. Stray fibres along the cuff edge (alpha-free; albedo fuzz only). The code hides hat and hair accessories under it. LOD0 800.
- **Balaclava** (`balaclava`, 40, 40, 45; covers the lower half of the head at y = −0.22 × head height). Thin polyester knit. Breathable mesh panel over the mouth (smaller holes visible in the albedo plus the normal), and a face opening edge with binding. Optional rime around the mouth panel in the Summit and High Altitude zones (white frost, roughness 0.9). LOD0 800.
- **Pants**:
  - Hiking pants (`hiking_pants`, 90, 85, 70; scale 1.06): stretch-woven nylon with articulated knees (2 darts), thigh cargo pocket flaps (flat, stitched) and a hem with a drawcord.
  - Insulated pants (`insulated_pants`, 30, 40, 60): quilted synthetic insulation with diamond quilting stitched through, full-length side zips, and **scuff guards on the inner ankles** (Cordura patches, darker, roughness 0.8, with crampon cut marks).

  Both: knee dirt and wear at the front of the LowerLeg/UpperLeg junction; the hem overlaps the boot cuff (see 2.6). LOD0 2,500.

---

### 2.8 Alpine expedition tent

**ASSET NAME** — `ExpeditionTent` (not built in code yet; proposed as a buildable structure in the `BuildingService` pattern).

**REAL-WORLD REFERENCE** — A 2-person, 4-season, double-wall geodesic dome.
- **Poles:** 4 aluminium poles (Ø 9.5 mm, shock-corded segments of about 45 cm, joined by ferrules) crossing at 5 points, sleeved through fly sleeves or held by clips on the inner tent.
- **Fly:** silicone-coated 40D ripstop nylon fly with one front vestibule (0.8 m deep) and one rear vent with a prop strut. Snow valances (25 cm skirts) sewn around the fly base.
- **Inner and floor:** 70D PU-coated nylon bathtub floor; inner walls in breathable nylon with a mesh panel at the door top.
- **Anchoring:** 8 guy-out points, each a reflective 3 mm cord through a line tensioner; aluminium V-stakes or buried snow-anchor plates.
- **Doors:** a two-way #8 door zip following the D-shaped door, with a storm flap.

**GAME PURPOSE** — A high-tier shelter: precipitation blocked, wind factor below the tarp's (tarp is 0.25 in code), and room for 2 players to rest.

**PLAYER SCALE** — Two R15 characters lie side by side inside the inner. A crouching character fits under the peak; a standing one does not. The vestibule holds a pack.

**APPROXIMATE DIMENSIONS** — Real inner 2.15 m L × 1.35 m W × 1.05 m H; footprint with vestibule 3.0 m × 1.9 m. @0.28: 7.7 × 4.8 × 3.75 studs. @0.35: 6.1 × 3.9 × 3.0 studs. **Target: inner 7.0 × 5.0 × 3.6 studs. Total footprint 9.6 × 6.0 studs including the vestibule; guy-out radius 2.5 studs beyond the fly.** The width is set by the 2-stud-wide R15 torso.

**SILHOUETTE** — A low, rounded dome: a near-hemispherical cross-section with the fly reaching the ground all round, the vestibule as a sloped wedge on one end, and taut panels between the poles with slight inward curvature (fabric under tension curves between supports; never flat planes). Guy lines run out at 35–45° from the pole crossings.

**PRIMARY COMPONENTS** — `Fly` (outer), `Inner` (visible through the open door only), `Floor` (PrimaryPart; bathtub edge rises 0.3 studs), `Pole` ×4.

**SECONDARY COMPONENTS** — Vestibule, door storm flap, rear vent with its strut, snow valances, `GuyLine` ×8, `Stake` ×8 (V-stakes driven at 60° away from the tent) or `SnowAnchor` ×8 (a buried plate with the cord disappearing into the snow), pole-tip grommets with webbing tabs at the fly corners.

**MECHANICAL COMPONENTS** — Pole ferrule joints (a slight 0.01-stud bulge every 1.6 studs along each pole), door zip with 2 sliders, line tensioners (small plastic plates on each guy line, 0.3 studs from the fly), and the vent strut.

**MATERIALS** — Fly: silnylon (warm yellow or orange is the realistic choice for visibility; final tint TBD by design). Floor: dark grey PU nylon. Poles: anodised grey aluminium. Guy lines: 3 mm cord, orange. Stakes: aluminium. Valances: matching fly fabric.

**MATERIAL ROUGHNESS** — Silnylon 0.40 (it has a satin sheen); floor 0.55; poles 0.35; cord 0.75; stakes 0.40.

**SURFACE DETAILS** — Tension wrinkles radiating from every guy-out point and pole clip. Catenary sag in unsupported panels (0.1–0.2 studs). Ripstop grid. Sleeve channels over the poles (the pole shape reads through the fabric).

**STITCHING** — Seams sealed on the fly. Seams show as a double row of lockstitch with a faint seam-tape line (fly undersides only). Bar-tacks on every guy-out tab.

**SEAMS** — Fly panel seams follow the pole arcs (pole sleeves are sewn into seams). Vestibule seam. Valance seam along the fly base.

**FASTENERS** — Door zip, buckle-adjustable corner straps (fly to the pole tip), toggles holding the rolled door open, and line tensioners.

**WEAR** — Faded fly top (UV exposure, 8% lighter). Abrasion on the floor corners. Pole anodise worn at the ferrules.

**SCRATCHES** — On stakes and poles only.

**DIRT** — On the floor's bathtub walls and the valance bottom edges. The vestibule ground is trampled (handled by the terrain or a decal mesh).

**MUD** — Below Snowline: the valances and floor edges are spattered.

**SNOW** — `RoofSnow` MeshParts (direct children, same behaviour as the tarp shelter): 2–4 conforming shells on the upper fly panels. Snow is thicker in the hollows between poles, thinner on the pole ridges, and cut off where the slope exceeds 50°. Static banked snow on the valances (blocks dug and piled on them), part of the "pitched on snow" variant.

**WATER RESPONSE** — Wet fly: darkened 25% with roughness 0.25. This needs a code hook like the clothing wetness (none today).

**DAMAGE** — Proposed durability states, mirroring the tarp: 100–50% intact. Below 25%, a torn guy-out tab and one slack panel (a swapped panel mesh with deeper sag and a flapping corner).

**ATTACHMENT POINTS** (proposed, matching `BuildingService` conventions) — Model PrimaryPart `Floor` (prompts attach here). Shelter interior box centred 1.8 studs above the floor, size 6.6 × 3.4 × 5.0 (local). `RoofSnow` parts are direct children. Attachments `GuyOut1..8` on the fly, each with a matching `GuyLine` ending at a `Stake`. `DoorPrompt` attachment at the door centre.

**ANIMATION** — Static mesh by default. Optional skinned fly (4–8 bones on the large panels) with a client-side script adding small flutter (≤ 0.05 studs) scaled by wind speed. Roblox has no vertex wind for MeshParts, so motion must come from bones.

**PLAYER INTERACTION** — "Rest inside" and "Repair" prompts, as with the tarp. Entering is via the door side only (collision, below).

**GAMEPLAY FUNCTION** — Weather protection and resting.

**COLLISION** — Fly: `PreciseConvexDecomposition` is wrong for a hollow dome (convex parts fill the interior). Use a separate invisible collision shell of 6–10 thin Parts for the walls with a door gap; the visual MeshParts get `CanCollide = false`. The floor collides (Box). Guy lines and stakes do not collide.

**LOD** — LOD0 6,000 / LOD1 2,500 / LOD2 600 tris.

**TEXTURE STRATEGY** — One 1024² fly map; a 512² floor and inner map; poles, stakes and tensioners on `ATLAS_Metal` and `TRIM_Webbing_Hardware`; guy lines as Beams with the shared rope texture (orange tint).

**ROBLOX OPTIMIZATION** — Fly and vestibule in one MeshPart; RoofSnow shells separate; poles merged into the fly mesh where they are inside the sleeves. Enable `DoubleSided` only on the fly if the inside is visible through the door.

**FINAL VISUAL TARGET** — A tent pitched by someone who knows how: taut panels, evenly tensioned guys, valances buried, snow collecting in the panel hollows.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no oversized poles. No floating components: every guy line ends at a stake or anchor, and the fly meets the ground. No impossible straps. No random decorative parts: no flags or windows that real tents lack. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: no flat pyramid faces. No disconnected components. No logos or text. No unrealistic materials: no plastic-shiny fly, no transparent panels.

---

### 2.9 Campfire

**ASSET NAME** — `Campfire`. Code parts: `Base` (PrimaryPart), `RingStone` ×9, `Log` ×3, `Char` ×3, `Embers` (hosts the `Fire`, `Smoke` and `PointLight`).

**REAL-WORLD REFERENCE** — A backcountry fire ring:
- 9 fist-to-head-sized granite stones in a 1 m ring on a cleared mineral-soil pad;
- a teepee lay of 3 split fuel logs (8–12 cm thick, 70–80 cm long) leaning to an apex over a kindling crib (6–10 sticks, 1–3 cm thick);
- a grey-white ash bed with glowing coals at the centre.

**GAME PURPOSE** — A warmth source (`NearFire` attribute; it melts the pack SnowCap faster), with fuel that runs out (`BuildingService` fuel and extinguish). A cooking and gathering point.

**PLAYER SCALE** — The ring's outer diameter is 70% of character height. The teepee apex is at knee-to-hip height.

**APPROXIMATE DIMENSIONS** — Real ring 1.0 m Ø, teepee 0.6–0.7 m tall. @0.28: 3.6 Ø, 2.3 tall. @0.35: 2.9 Ø, 1.9 tall. **Target (greybox): pad 3.6 Ø; ring stones centred at r = 1.75; apex 2.1 studs; logs Ø 0.32; ember bed 1.6 Ø.**

**SILHOUETTE** — A low ring of irregular stones, each a different size (0.7–1.0 × 0.45–0.65 × 0.55), tilted ±10°. A teepee of 3 logs whose feet rest at r = 1.15, inside the ring. The logs touch each other at the apex and **cross**: they rest against each other and do not intersect through each other's centres.

**PRIMARY COMPONENTS** — Ring stones, fuel logs, ash and ember bed (`Embers`), soil pad (`Base`).

**SECONDARY COMPONENTS** — Kindling crib inside the teepee (6–10 thin sticks, lying on the ember bed); 2–3 unburnt log ends outside the ring as a fuel pile (optional); soot staining on the inner faces of the ring stones.

**MECHANICAL COMPONENTS** — None.

**MATERIALS** — Granite stones; pine logs with bark (bark is lost on the charred upper third); charcoal; ash; soil.

**MATERIAL ROUGHNESS** — Stone 0.80 (soot-blackened inner faces 0.90); bark 0.90; char 0.85 (alligator-cracked, with a slight sheen on the crack ridges at 0.70); ash 0.95; soil 0.95.

**SURFACE DETAILS**
- **Char:** alligator cracking (rectangular checks 0.04–0.08 studs), progressing from fully cracked black at the apex end to a browned, scorched transition 0.4 of the log length down.
- **Logs:** split faces with growth rings on the log ends.
- **Ash:** fine powder that collects in the gaps between stones.

**STITCHING** — Not applicable.

**SEAMS** — Not applicable.

**FASTENERS** — Not applicable.

**WEAR** — Stones fire-cracked: 1–2 have a spall missing (a fresh, lighter fracture face).

**SCRATCHES** — Not applicable.

**DIRT** — Soot gradient on the ring stones (black at the inner base, fading to clean grey on the outer top); scattered ash and charcoal fragments on the pad.

**MUD** — Below Snowline, the pad edge blends into mud (terrain).

**SNOW** — Static: snow on the outer tops of the ring stones only, with a melted ring (a 0.5-stud bare zone) around the outside. No snow on the logs or inside the ring while burning.

**WATER RESPONSE** — Not driven. A rain variant: stones darker (wet granite 0.35 roughness), ash becomes a grey paste (albedo darker, roughness 0.6).

**DAMAGE** — Fuel states, each a swappable `Log` and `Embers` set: **Burning** (full teepee, bright coals); **Low** (logs burnt to 60% length, collapsed inward: the apex is lost and the logs lie on the ember bed); **Out** (charred stubs, grey ash, no Neon, no light).

**ATTACHMENT POINTS** (code contract) — `Base` is the PrimaryPart at `at × (0, 0.1, 0)`. `Embers` is at `at × (0, 0.26, 0)` and must remain a BasePart (the Fire, Smoke and PointLight are parented to it).

**ANIMATION** — Fire and smoke are engine effects. The ember glow can pulse via script (PointLight Brightness 2.2–2.8, and Neon Color). No mesh animation.

**PLAYER INTERACTION** — `BuildingService.attachFirePrompts` (add fuel, cook, etc.). The prompt hosts on the model; keep the existing part names.

**GAMEPLAY FUNCTION** — Warmth radius 2.5 (`radius`), fuel, light at night (PointLight range 22).

**COLLISION** — Currently nothing collides. Recommended: ring stones `CanCollide = true` with `CollisionFidelity = Hull` (they are small and convex), so players step over them; logs, embers and pad off. `CanQuery = false` on the embers.

**LOD** — LOD0 3,000 / LOD1 1,200 / LOD2 300 tris (whole prop). The stones become a single ring mesh at LOD2.

**TEXTURE STRATEGY** — Stones and logs from `ATLAS_Wood_Bark` plus a 512² rock-detail map. Embers: SurfaceAppearance is not used on `Embers`, because it must be `Neon` to glow. Roblox SurfaceAppearance has no emissive channel to our knowledge (verify). Model the ember mesh as broken lumps of coal (not a disc), with the Neon applied only to the coal lumps in a separate MeshPart.

**ROBLOX OPTIMIZATION** — Stones merged into one MeshPart; logs into one; char into the logs (texture gradient, no separate `Char` part). Keep a part named `Embers`. `Smoke.Opacity` is already low (0.08). `PointLight.Shadows = true` is expensive: allow only one shadow-casting fire light within 60 studs of the camera (follow-up 6.7).

**FINAL VISUAL TARGET** — A fire someone built with care: the stones are blackened inside, the logs are charred from the top down with bark still on their lower ends, the coal bed has orange lumps under grey ash and the kindling is visible through the teepee gaps.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no cartoon log stack, no identical stones. No floating components: the logs rest on the ground and on each other. No impossible straps. No random decorative parts: no cooking pot unless gameplay has one. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: the stones are not cubes. No disconnected components. No logos or text. No unrealistic materials: no flat Neon disc, no blue flames.

---

### 2.10 Emergency tarp shelter

**ASSET NAME** — `TarpShelter` (built) and `TarpRoll` (stowed, see 2.1).

**REAL-WORLD REFERENCE** — A 3 × 3.5 m silnylon or PU-coated polyester tarp pitched in an A-frame:
- **Ridgeline:** a 4 mm static cord ridgeline tied between two cut wooden poles (Ø 5–6 cm, about 1.5 m) and continuing past each pole top to a guy stake.
- **Tie-outs:** the tarp's edge has sewn webbing loops at the corners and mid-edges, each reinforced with a bar-tacked triangular patch and holding a guy loop to a stake.
- **Ridge:** the ridge seam drapes over the ridgeline.

**GAME PURPOSE** — An early shelter: wind factor 0.25, precipitation blocked, durability that decays with high wind, repairable with rope (`Reinforce (1 rope)`), collapses at 0.

**PLAYER SCALE** — The ridge is just above character height (5.2 studs); one character stands under the ridge, and two lie side by side.

**APPROXIMATE DIMENSIONS** — Real ridge length 3.0 m, slope 1.75 m per side, ridge 1.5 m high. @0.28: 10.7 × 6.25 per side × 5.4 high. @0.35: 8.6 × 5.0 × 4.3. **Target (greybox): length 9, half-width 3.6, ridge 5.2; poles to 5.5; guy stakes 2.5 beyond each end.**

**SILHOUETTE** — An A-frame with two sloping planes that **sag**: each panel dips 0.25 studs at mid-length (catenary along the ridge) and bellies 0.1–0.15 studs inward across the slope. The ridge is a slightly drooping line, and guy lines run from the pole tops to the end stakes.

**PRIMARY COMPONENTS** — `TarpPanel` (the tarp as one continuous sheet; the greybox's 4 panels become one mesh with a ridge fold), `Pole` ×2, `RidgeLine`.

**SECONDARY COMPONENTS** — `Stake` ×6 (corners plus mid-edges), `GuyStake` ×2, `GuyLine` ×2, tie-out loops ×6 (webbing), ridge tie-outs ×2 at the tarp ends.

**MECHANICAL COMPONENTS** — Knots: a trucker's hitch at one end of the ridgeline and a bowline at the other (modelled as small bulges with a wrapped texture); prusik loops on the ridgeline holding the tarp's ridge tie-outs.

**MATERIALS** — Tarp: PU-coated polyester (ItemDefs 60, 110, 70). Poles: debarked spruce or fir saplings (bark stripped at the top where the line wraps). Cord: nylon (orange, 220, 110, 40). Stakes: aluminium Y-stakes.

**MATERIAL ROUGHNESS** — Tarp 0.55; poles 0.85 (bark) and 0.70 (stripped); cord 0.75; stakes 0.40.

**SURFACE DETAILS** — Tension wrinkles fan from every tie-out. The ridge fold is crisp. Slack panels show diagonal wrinkles toward the corners. A dew or condensation sheen on the underside (roughness 0.4).

**STITCHING** — Hemmed edges (double-fold hem, a single stitch row 0.06 studs from the edge), bar-tacked tie-out loops, a box-X on the corner patches.

**SEAMS** — One centre seam across the tarp's width at the ridge (a typical construction from two widths of fabric), seam-sealed.

**FASTENERS** — Knots, prusiks and the stake loops. **Every tie-out loop must reach a stake.** The stake's head shows the loop wrapped under its hook.

**WEAR** — Faded top surface; abraded edges where they contact the ground.

**SCRATCHES** — Not applicable (fabric). Stakes are scratched at the head (hammered with a rock).

**DIRT** — Soil splash along the bottom 0.3 studs of each panel. Pole bottoms are dark and wet-looking where they meet the ground.

**MUD** — Below Snowline: mud on the edges and pole feet.

**SNOW** — `RoofSnow` ×2 (direct children, code contract): conforming shells following each sagged panel, thicker toward the bottom edge (snow slides and collects), thinner at the ridge, with a slight overhang lip of ≤ 0.1 studs at the bottom edge. They fade from Transparency 1 to 0.1 (code).

**WATER RESPONSE** — Wet variant (rain zones): darker by 20%, roughness 0.30; droplet normal on the top surface.

**DAMAGE** — Durability visuals (proposed, code hook needed):
- ≤ 25%: one corner tie-out torn free. The tarp corner lifts and flaps (a swapped corner mesh), and the stake stands alone with its loop torn.
- 0: collapse. The model is removed by code.

**ATTACHMENT POINTS** (code contract) — `Floor` is the PrimaryPart (prompts "Rest under the tarp" and "Reinforce" anchor to it), at `at × (0, 0.08, 0)`. `RoofSnow` parts are direct children. Interior box: `at × (0, 2.6, 0)`, size 6.6 × 5.2 × 9.

**ANIMATION** — Optional: skinned tarp (6–8 bones) with a client flutter driven by wind speed; amplitude rises as durability falls.

**PLAYER INTERACTION** — Rest (E), Reinforce (F, hold 1.5 s, consumes 1 rope).

**GAMEPLAY FUNCTION** — Shelter with decay; it teaches the player about wind.

**COLLISION** — The tarp collides (the code sets `TarpPanel` to collide). A single Box or Hull around an A-frame mesh would fill the space under the roof, so either split the visual into two MeshParts (one per side) with `CollisionFidelity = Hull`, or keep the visual mesh non-colliding and add two invisible thin Parts, one along each slope, as the collider (recommended: cheapest and exact). Poles collide (Box); cord and stakes do not.

**LOD** — LOD0 2,500 / LOD1 1,000 / LOD2 250 tris.

**TEXTURE STRATEGY** — A 1024² tarp map (top and underside share UVs; `DoubleSided` on the tarp MeshPart). Poles from `ATLAS_Wood_Bark`; cord from the shared rope texture (or Beams); stakes on `ATLAS_Metal`.

**ROBLOX OPTIMIZATION** — Tarp as one MeshPart (DoubleSided); the 2 poles plus ridge cord as one; stakes merged per side. RoofSnow stays separate.

**FINAL VISUAL TARGET** — A taut but naturally sagging tarp, every edge loop tied down, a ridgeline knot visible at the pole, and snow piling toward the eaves.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no thick board-like tarp (it is ≤ 0.03 studs thick visually). No floating components: no tarp corner hovering above a stake. No impossible straps: the guy lines run to stakes in straight lines (cord under tension does not sag visibly over 3 studs). No random decorative parts. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: no flat planes. No disconnected components. No logos or text. No unrealistic materials: no Neon or plastic.

---

### 2.11 Wind wall

**ASSET NAME** — `WindWall`. Code parts: `Base` (PrimaryPart), `Post` ×2 (→ 4, follow-up 6.5), `Log` ×7.

**REAL-WORLD REFERENCE** — A log windbreak. Two pairs of stakes are driven 40 cm into the ground about 3.5 m apart. Peeled or barked logs (15–22 cm) are stacked horizontally between each pair, each log resting on the one below. The stake pairs are lashed together across the top with cord so the stack cannot spread. The windward base is banked with snow or soil.

**GAME PURPOSE** — Wind factor 0.4 within a 5.5-stud radius. A cheap camp improvement.

**PLAYER SCALE** — Height equals character height (5 studs). Width is 2.2× character height.

**APPROXIMATE DIMENSIONS** — Real 3.5 m × 1.6 m × 0.25 m. @0.28: 12.5 × 5.7 × 0.9. @0.35: 10 × 4.6 × 0.7. **Target: 11 × 5 × 0.62 studs, posts Ø 0.3 driven 0.5 into the ground and rising to 5.4.**

**SILHOUETTE** — A horizontal stack of slightly uneven logs (each Ø 0.55–0.70, with ends cut at slightly different lengths and angles) between two pairs of posts. A cord lashing between each post pair just above the top log.

**PRIMARY COMPONENTS** — `Log` ×7–8 (stacked in contact; each log rests on the one below along at least 60% of its length), `Post` ×4 (a pair at each end, one on each face of the stack, at z = ±0.4).

**SECONDARY COMPONENTS** — Top lashings ×2 (cord wraps over the top log binding each post pair), a snow or soil berm on the windward face (part of `Base`).

**MECHANICAL COMPONENTS** — None.

**MATERIALS** — Barked pine logs, sharpened post bottoms, nylon or natural cord.

**MATERIAL ROUGHNESS** — Bark 0.90; cut ends 0.75; cord 0.75.

**SURFACE DETAILS** — Saw or axe cuts on the log ends (axe-cut ends are faceted, with V-shaped chops). Bark plates. Knots and branch stubs flush-cut.

**STITCHING** — Not applicable.

**SEAMS** — Not applicable.

**FASTENERS** — Cord lashings (a square lashing pattern) at the post tops.

**WEAR** — Bark scraped off where the logs contact the posts.

**SCRATCHES** — Not applicable.

**DIRT** — Soil on the bottom log and the post bases.

**MUD** — Below Snowline: mud at the base.

**SNOW** — Static: snow on the top surface of each log (thin, 0.03–0.06), thickest on the top log; a windward drift banked to 1/3 of the height; a leeward scoop (a bare hollow) right behind the wall.

**WATER RESPONSE** — Rain variant: bark darker by 25%, cut ends darker.

**DAMAGE** — None.

**ATTACHMENT POINTS** — `Base` is the PrimaryPart at `at × (0, 0.1, 0)`.

**ANIMATION** — None.

**PLAYER INTERACTION** — None beyond placement.

**GAMEPLAY FUNCTION** — Wind reduction.

**COLLISION** — The logs collide as one combined collider: a single invisible Box (11 × 5 × 0.7) is cheaper than 7 cylinders. Posts: Box.

**LOD** — LOD0 3,000 / LOD1 1,200 / LOD2 250 tris.

**TEXTURE STRATEGY** — `ATLAS_Wood_Bark` only (plus a shared snow overlay).

**ROBLOX OPTIMIZATION** — One MeshPart for all logs and posts; one collision Part; snow as a separate MeshPart only if it needs to be toggled.

**FINAL VISUAL TARGET** — A wall that could stand on its own: logs nest on each other, the post pairs pinch the stack, the lashings hold the posts, and snow drifts on the windward side.

**NEGATIVE REQUIREMENTS** — No toy-like proportions. **No floating components: no log hovering with a gap above the log below** (the greybox spaces the logs 0.714 apart at Ø 0.62, leaving 0.09-stud gaps, and its logs stop 0.2 short of the posts; see follow-up 6.5). No impossible straps. No random decorative parts. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: no identical cylinders. No disconnected components. No logos or text. No unrealistic materials.

---

### 2.12 Trail marker

**ASSET NAME** — `TrailMarker`. Code parts: `Stake` (PrimaryPart), `Flag` (hosts the `PointLight`). A `BillboardGui` is added by `BuildingService`.

**REAL-WORLD REFERENCE** — A glacier and snow route wand: a 1.8 m wooden or bamboo stake, 2.5 cm thick, pointed at the bottom, with a 25 × 35 cm fluorescent nylon flag tied to the top by 2 cord ties through its hemmed hoist sleeve.

**GAME PURPOSE** — Route marking that is visible through fog (the BillboardGui is AlwaysOnTop with a 400-stud MaxDistance; the PointLight has a range of 10).

**PLAYER SCALE** — The top of the flag is above head height (5.6 studs).

**APPROXIMATE DIMENSIONS** — Real 1.8 m (0.2 m buried) × Ø 0.025 m; flag 0.25 × 0.35 m. @0.28: 6.4 tall, flag 0.9 × 1.25. @0.35: 5.1, flag 0.7 × 1.0. **Target (greybox): stake from −0.6 to 5.6, Ø 0.22 (a 2.5× exaggeration of thickness for readability); flag 0.8 tall × 1.2 long, its top edge at 5.4.**

**SILHOUETTE** — A thin vertical stake with a rectangular flag hanging from its top on one side, droop-curled (the flag's free corner sags 0.1–0.2 studs below its hoist corner).

**PRIMARY COMPONENTS** — `Stake`, `Flag`.

**SECONDARY COMPONENTS** — 2 cord ties at the top and bottom of the flag's hoist edge, wrapping the stake; the cut point at the bottom (hidden in the ground).

**MECHANICAL COMPONENTS** — None.

**MATERIALS** — Stake: split or peeled pine (or bamboo with nodes every 1 stud). Flag: fluorescent orange nylon (sRGB ≈ 255, 110, 20).

**MATERIAL ROUGHNESS** — Stake 0.80; flag 0.55.

**SURFACE DETAILS** — Hemmed flag edges; a frayed free edge (alpha-cut fringe of 0.03 studs); knife-cut marks on the stake top.

**STITCHING** — Single-row hem around the flag; the hoist sleeve is sewn.

**SEAMS** — Hoist sleeve seam.

**FASTENERS** — 2 cord ties (clove hitches) through grommets at the sleeve's top and bottom.

**WEAR** — UV-faded flag on its upper half (−10% saturation); frayed fly end.

**SCRATCHES** — Not applicable.

**DIRT** — The stake is darker at the snow or soil line.

**MUD** — Below Snowline: mud on the bottom 0.4 studs of the stake.

**SNOW** — Static: rime on the windward side of the stake (a white crust strip, 0.02 thick) in the Summit and High Altitude zones; a small snow cap on the stake top.

**WATER RESPONSE** — The flag darkens 20% when wet (rain variant).

**DAMAGE** — None.

**ATTACHMENT POINTS** (code contract) — `Stake` is the PrimaryPart (a cylinder from `at × (0, −0.6, 0)` to `at × (0, 5.6, 0)`); `Flag` is a BasePart at `at × (0, 5.0, 0.6)` with the PointLight. The BillboardGui sits 6.5 studs above.

**ANIMATION** — Static, pre-posed with a light droop. Optional: rotate the flag about the stake axis to face downwind (a cheap CFrame yaw on the client) so that all flags agree with the weather.

**PLAYER INTERACTION** — Placement only.

**GAMEPLAY FUNCTION** — Wayfinding in whiteouts.

**COLLISION** — The stake collides (Box, small). The flag has no collision and no query.

**LOD** — LOD0 400 / LOD1 150 / LOD2 40 tris.

**TEXTURE STRATEGY** — The stake on `ATLAS_Wood_Bark`; the flag as a 256² unique map with an alpha fringe (`AlphaMode = Transparency`), `DoubleSided`.

**ROBLOX OPTIMIZATION** — 2 MeshParts (the flag needs DoubleSided and alpha). **Replace the flag's `Neon` material** (follow-up 6.6): fabric is not emissive, and the BillboardGui and PointLight already guarantee fog visibility.

**FINAL VISUAL TARGET** — A real route wand: a thin stake and a small, saturated orange flag tied on with two hitches, faded and frayed after days in the wind.

**NEGATIVE REQUIREMENTS** — No toy-like proportions: no giant flag. No floating components: the flag's hoist edge wraps the stake. No impossible straps. No random decorative parts: no lamps, no reflectors that real wands lack. No excessive geometry. No perfectly clean surfaces. No generic low-poly look: no hexagonal stake at LOD0 (≥ 8 sides). No disconnected components. No logos or text. No unrealistic materials: no glowing fabric.

---

## 3. Family specs

### 3.1 Rocks — modular kit

**Reference geology.** The mountain is crystalline (granite and gneiss) with a schist band. Rock breaks along **joint sets**: two near-vertical sets roughly perpendicular to each other and one gently dipping set. Fragments are therefore blocky, with flat fracture faces meeting at 70–110°. Edges are rounded on old surfaces and sharp on fresh breaks. Lichen covers the old faces below the Frozen Ridge (y < 330); above it there is none. All of this must be consistent across the whole map: **in one region, every rock's bedding and joint planes share one dip direction (±10°).**

| Family | Size (studs) | Use | LOD0 / LOD1 / LOD2 tris | Collision | Notes |
|---|---|---|---|---|---|
| Small | 0.3–1.5 | Scatter, cairn stones, fire-ring stones | 150–400 / 80 / 20 | none (< 0.8), Box (≥ 0.8) | 12 unique shapes; flat bottoms so they sit on the ground |
| Flat (slab) | 2–6 × 0.4–1.0 thick | Stepping slabs, talus plates, shelter floors | 400–800 / 250 / 60 | Box | Aligned to the slope normal ±5°; one face is an old weathered bedding surface |
| Boulder | 3–10 | Landmarks, windbreaks, rockfall debris | 1,500–3,000 / 800 / 200 | Hull | 8 unique; 15–30% buried; glacial-erratic variants are more rounded |
| Cliff modules | 20–60 faces, 8–20 deep | Climbable walls, ridges | 5,000–8,000 / 2,500 / 600 | PreciseConvexDecomposition (raycasts for climbing hit collision geometry) | Tagged `Climbable`; snap kit: straight, inside corner, outside corner, top cap, base talus; edges overlap 1–2 studs into neighbours or terrain |
| Broken (fracture sets) | 2–8 | Rockfall zones, talus fields | 600–1,500 / 400 / 100 | Hull | Sets of 3–5 pieces whose fracture faces **match** (they can reassemble); fresh faces lighter and lichen-free |
| Sharp alpine | 1–8 | Frozen Ridge and above | 800–2,000 / 500 / 120 | Hull | Frost-shattered: angular, sharp edges, no rounding, no lichen, rime on windward edges |
| Wet | any of the above | Stream banks, melt zones | same meshes | same | Material variant only: albedo −30%, roughness 0.35, darker band at the waterline, moss (green-brown, roughness 0.9) below y = 95 |
| Snow-covered | any of the above | Above the snowline (code flag) | +200–600 for the cap | none on the cap | A separate snow-cap MeshPart conforming to the up-facing surfaces (see rules), or a baked "snowed" texture variant |

**Construction.** Silhouettes come from planar fracture faces; the normal map carries only grain, micro-fractures and pits. No noise-displaced blobs. Bevel radius: 0.02–0.05 studs on fresh edges, 0.15–0.4 on weathered ones.

**Rotation and scale rules**
- Yaw: free (0–360°), **except cliff modules and slabs, whose strata must match the region's dip direction (±10°).**
- Pitch and roll: boulders ±15°; small rocks free; slabs follow the ground normal ±5°; cliffs ±5°.
- Scale: uniform 0.75–1.35. Non-uniform ≤ ±10% per axis (larger stretches show stretched texels and lichen).
- Burial: 15–30% of height below ground (the code sinks clusters by 0.2 × size). **No visible gap between any rock and the ground or its neighbour.** Check at four points around the base.
- Snow caps follow **world up**. A baked-snow variant may only be yaw-rotated; pitched or rolled rocks use a separate cap mesh sampled after placement.
- No two identical rocks within 30 studs of each other (same mesh, same rotation, same scale ± 5%).

**Textures.** A 1024² shared rock atlas per geology (granite, schist) with 4–6 tileable regions plus unique boulder bakes (normal only). Lichen and moss go in a second UV channel only if the importer and SurfaceAppearance support it (they do not use a second UV set to our knowledge, so bake lichen into the unique maps instead).

### 3.2 Pine trees by altitude band

Altitude bands come from `ZoneDefs.luau`. The code thins trees with altitude (scale 1 → 0.35 above y = 40) and stops them at snowline + 30 (y = 165). Trees are snowy from y ≥ snowline − 10 (y = 125).

| Band (y studs) | Species reference | Form | Height (code: 16–30 × region scale × altitude scale) | Snow load |
|---|---|---|---|---|
| Base Forest (< 30) | Norway spruce / silver fir | Narrow conical crown to 1/4 height; the lower 1/4 of the trunk has dead, self-pruned branch stubs; dense stands | 22–30 studs | none |
| Rocky Forest (30–95) | Spruce with European larch | Sparser crowns; 10% dead snags with no needles and silvered bark; roots gripping rock | 16–26 | none |
| Alpine Meadow (95–135) | Swiss stone pine / subalpine fir | Broad, irregular crowns; trunks often forked; isolated trees | 9–16 | dusting from y ≥ 125 |
| Snowline (135–165) | Krummholz spruce / dwarf pine | **Wind-flagged**: branches only on the leeward side, stunted (code 0.35 scale), half-buried, multi-stemmed mats | 5–9 | heavy |

**Construction**
- **Trunk:** tapers continuously from the root flare (1.8× trunk Ø over 0.8 studs) to the leader. Trunk Ø = 0.05 × height, as in the greybox, which is stocky; acceptable for subalpine trees. For Base Forest trees use 0.035.
- **Branches:** in **whorls**. A spruce whorl is 4–6 branches at one height, with whorl spacing = 0.035 × height. Branch geometry carries **needle-cluster alpha cards** (`AlphaMode = Transparency`). Cards attach along the branch, never floating in the crown. Spruce branches droop at their tips; pine branches are upswept with tufts at the ends.
- **Bark:** spruce has thin red-brown scaly plates (roughness 0.9); larch has deep furrows; stone pine is grey and smooth when young. Resin streaks at wounds (roughness 0.4, amber).
- **Dead branch stubs:** grey (70, 58, 48), on the lower trunk (the greybox's `DeadBranch`).
- **Snow load:** a **separate snowy mesh variant**, because the branches bend 10–20° further down under load. Snow sits on the upper face of each branch's card mass as its own alpha-card layer (`ATLAS_Snow_Overlay`) that stops at the branch tips. There is no snow on the trunk except on the windward side (rime strip) at the Snowline band.

**Budgets**
- LOD0: 4,000–6,000 tris (Base Forest), 2,500–3,500 (Snowline).
- LOD1: 1,500.
- LOD2: 300 (simplified card clusters).
- LOD3 / impostor: 2–3 crossed alpha quads (≤ 12 tris) beyond ~500 studs.

Roblox has no authored-LOD swap for a single MeshPart. Either rely on `RenderFidelity = Automatic` (which degrades alpha cards poorly), or swap LOD meshes from a client script by distance (recommended for trees). `Model.LevelOfDetail = StreamingMesh` gives engine-generated far meshes when StreamingEnabled is on; verify its quality on alpha foliage before relying on it.

**Collision.** The trunk only: one invisible Part (cylinder or Box) or the trunk MeshPart with `CollisionFidelity = Hull`. Foliage: `CanCollide = false`, `CanQuery = false`, `CanTouch = false`, so placement and climbing raycasts pass through needles.

**Textures.** One 1024² needle-card atlas shared by all species (6–8 branch-tip card types with alpha) and one 1024² bark atlas. Per-band tint differences come from the albedo regions, not new textures.

### 3.3 Snow states

Terrain is the primary surface. Roblox terrain uses one look per base material. A `MaterialVariant` applied to terrain replaces that base material's look **everywhere** in the place, through `MaterialService` base-material overrides. Distinct snow states therefore need distinct base materials. The plan below repurposes base materials the world does not otherwise use.

**Do not repurpose any material listed in `ClimbConfig`** (Rock, Slate, Basalt, Limestone, Sandstone, Granite → climbable rock; Ice, Glacier → climbable ice). Do not repurpose Grass, Ground, Mud or Water (WorldBuilder uses them).

| State | Where | Base material | MaterialVariant | Albedo | Roughness | Normal / pattern | StudsPerTile |
|---|---|---|---|---|---|---|---|
| Fresh | Default above the snowline | Snow | `Snow_Fresh` | 236–245, cool blue in shade | 0.85 | Soft pillowed micro-relief; `Pattern = Organic` | 10–14 |
| Packed | Trails, camp clearings, around structures | Salt | `Snow_Packed` | 215–225, slightly grey | 0.65 | Bootprint compression, flattened; Organic | 8 |
| Wet / slush | Lower snowline, stream banks, melt zones | Pavement | `Snow_Wet` | 185–205, blue-grey, with darker water-saturated patches | 0.30 | Pitted, granular (corn snow), puddle flats | 8 |
| Dirty | Avalanche debris, rockfall zones, camp periphery | Asphalt | `Snow_Dirty` | 170–200 with grey-brown speckle, embedded grit, needles and rock chips | 0.70 | Lumpy debris blocks | 12 |
| Icy (crust / refrozen) | Exposed ridges, wind-scoured slopes | Ice (already climbable with an axe: acceptable on steep faces, irrelevant on flat ground) | `Ice_Crust` | 200–220, faint blue | 0.20–0.35 | Glazed sheet with cracks; Regular | 16 |
| Windblown (sastrugi) | Summit, High Altitude plateaus | Concrete | `Snow_Windblown` | 230–240 | 0.75 | Directional ridges aligned with the prevailing wind; `Pattern = Regular` so the ridges stay parallel | 16 |

- **Transitions.** Terrain blends neighbouring materials at voxel resolution (4 studs) automatically. Painted state boundaries should follow logic: packed along routes, dirty in fall lines below cliffs, icy on convex wind-exposed crests, windblown on flat high ground.
- **Footprints, drag marks, ski tracks, soot.** Thin MeshParts that conform to the terrain, with a SurfaceAppearance (`AlphaMode = Transparency`), `CanCollide`, `CanQuery` and `CanTouch` false, `CastShadow = false`. Cap them at about 100 live decals per client, with fade-out. Roblox terrain itself does not accept Decals.
- **Terrain colour.** `WorldBuilder` calls `Terrain:SetMaterialColor` for Snow (236, 241, 248) and Glacier (170, 205, 230). Whether material colour tints a MaterialVariant override on terrain needs to be verified in Studio. Author the variant albedo to look right with that tint applied **and** without it.
- **Matching props.** Every snow cap on props (SnowCap, RoofSnow, rock and bough caps) uses the same albedo and roughness as `Snow_Fresh`, so caps and terrain match in every lighting state.

### 3.4 Ice

Types: glacier blue ice (Glacier terrain plus serac and ice-wall MeshParts), water ice (frozen falls; climbable parts tagged `Climbable` with attribute `Ice = true`), verglas (thin clear ice on rock), lake and stream ice.

**Ice is not glass.**
- Do not use `Enum.Material.Glass`: it reads as a window pane and refracts like one.
- Do not make large surfaces transparent.
- Ice is opaque at mass scale. Its "depth" is painted into the albedo, and translucency is limited to thin edges.

| Property | Spec |
|---|---|
| Base mesh | Opaque MeshPart (Transparency 0). Faceted, conchoidal fracture surfaces on broken ice. Melt-rounded, fluted surfaces on falls (vertical candles and columns 0.3–1.5 studs Ø). |
| Blue depth | Albedo gradient: thick and recessed areas 140, 185, 215 (saturated cyan-blue); near the surface and on convex areas 210, 230, 240; snow-dusted tops 235, 242, 248. Concave fracture faces are bluest (light travels further through the ice). |
| Internal cracks | White planar fracture lines painted in the albedo (lighter, 2–3 px), with a faint normal step where they reach the surface. 3–8 per 10 × 10-stud area, oriented consistently (stress direction). |
| Air bubbles | White specks in columns and streaks (vertical in falls, horizontal layers in glacier ice). |
| Dirt bands | Glacier ice: brown-grey sediment layers (bands 0.2–1 stud thick) following the flow layering. Water ice: tannin-tinted amber streaks at the base. |
| Transparency variation | Only on an optional thin outer shell, ≤ 0.1 studs thick, on icicle tips and the thin edges of free-hanging ice. Shell Transparency 0.25–0.45 with `AlphaMode = Transparency`. Keep transparent area under 10% of any ice asset (sorting cost). |
| Roughness | Sun-glazed vertical faces 0.10–0.20; fresh fractures 0.25; frosted and rimed 0.70; snow-covered 0.85. |
| Metalness | 0 |
| Climbing | Climbable ice parts: `CanQuery = true`, tag `Climbable`, attribute `Ice = true`, `CollisionFidelity = PreciseConvexDecomposition` for wall-like shapes (the climbing raycasts hit collision geometry). |
| LOD | Ice walls: LOD0 4,000–6,000 / LOD1 2,000 / LOD2 500; icicle clusters: 600 / 200 / 50. |

---

## 4. Realism quality gate (15 questions)

An asset ships only when every answer is **yes**. The reviewer records the answers in the asset's hand-off note, with screenshots at 3, 30 and 100 studs under overcast daylight, low sun, campfire-only night and whiteout fog.

- [ ] 1. **Proportion:** Placed beside the R15 rig in Studio, does it match the target studs in this document, checked by measurement and not by eye?
- [ ] 2. **Manufacturable:** Could a factory make it as modelled? Does every panel have a seam, and was every hard part plausibly forged, stamped, moulded or cut?
- [ ] 3. **Connected:** Does every component physically touch what holds it, with no gaps and no floating parts, in every pose the code produces (held, stowed, R15 joints at ±90°)?
- [ ] 4. **Straps:** Does every strap start and end at a real termination (bar-tack, buckle, ladder-lock, loop) and follow a path it could hold under tension?
- [ ] 5. **Fasteners:** Does every buckle join two straps, every zipper follow an opening with a pull and end stops, and every knot or rivet sit where a load passes?
- [ ] 6. **Materials:** Are metalness and roughness within the table in 1.3, with no metallic fabric, no plastic-shiny textiles and no chrome?
- [ ] 7. **Wear:** Is wear located where hands, ground, rock, straps or tools actually touch, and absent elsewhere?
- [ ] 8. **Dirt and mud:** Is grime driven by gravity and contact (bottoms, seams, crevices), never applied as uniform noise?
- [ ] 9. **Snow:** Does snow sit only on surfaces facing world up, thickest where it would collect, and do the code-faded parts (`SnowCap`, `RoofSnow`) fade in without z-fighting or overhanging?
- [ ] 10. **Water:** At 35% code darkening plus the wet roughness variant, does it read as wet fabric or rock rather than a different colour or a chalky surface?
- [ ] 11. **Silhouette:** At 30 and 100 studs, is the asset identifiable from silhouette alone and distinct from its neighbours (for example, pack tiers)?
- [ ] 12. **Budget:** Are LOD0, LOD1 and LOD2 within their triangle budgets, are textures ≤ 1024² on the shared atlases, and do LOD switches preserve the silhouette?
- [ ] 13. **Code contract:** Do the names, PrimaryPart, origins and anchors (`Body`, `UpperBody`, `Lid`, `SnowCap`, `RoofSnow`, `Embers`, `Floor`, `Axe` / `Rope` / `Tarp` / `Wood`, the grip origin 1.6 studs below the axe head) match the code exactly?
- [ ] 14. **Clean of noise:** Is it free of logos, text, toy-like bevels and colours, and any part that serves no real function?
- [ ] 15. **Lighting:** Does it hold up in all four lighting states, with no unlit black interiors, no Neon used on anything that does not emit light, and correct shading of normal maps on both sides of DoubleSided parts?

---

## 5. Roblox implementation notes

Statements marked *(verify)* reflect our understanding at the time of writing. Confirm them in current Studio before building on them.

### 5.1 MeshPart templates, not runtime construction
- Scripts cannot assign `MeshPart.MeshId` at runtime except through `AssetService:CreateMeshPartAsync` *(verify)*. `RenderFidelity` and `CollisionFidelity` are Studio-only properties.
- **Ship each asset as a template Model** (for example in `ServerStorage/Assets` or `ReplicatedStorage/Assets`). `AssetFactory` builders then `:Clone()` the template and keep returning the same model names, PrimaryParts and anchor CFrames.
- Keep the greybox builders as a fallback when a template is missing, so gameplay never breaks while art is in progress.
- Anchor CFrames can move into the templates as `Attachment` instances named `Axe`, `Rope`, `Tarp` and `Wood` (read as `attachment.CFrame` in pack space). That way the art, not the code, owns the numbers. If that is done, keep the values in the table in 2.1.

### 5.2 SurfaceAppearance
- Applies to MeshParts. Maps: `ColorMap` (sRGB), `NormalMap` (tangent space, OpenGL / Y+ convention *(verify)*), `RoughnessMap` and `MetalnessMap` (linear).
- Images upload at ≤ 1024² (larger ones are downsampled).
- Texture IDs on a SurfaceAppearance cannot be changed by scripts at runtime *(verify)*. To switch between a dry and a wet look, author two SurfaceAppearance instances and **reparent a pre-authored clone**; do not edit IDs.
- Roblox SurfaceAppearance has no emissive map *(verify)*. Glowing things (coals) use a separate `Neon` part.
- `AlphaMode`:
  - `Overlay`: ColorMap alpha blends the map over the MeshPart's `Color`.
  - `Transparency`: alpha cut-out or blend for needles, flag fringes and decals.
  - A tint-mask mode with a `SurfaceAppearance.Color` property has been added in recent engine versions *(verify name and availability)*.

### 5.3 Making code tints and wetness work with SurfaceAppearance
`EquipmentService` writes `BasePart.Color` for both the item tint and the 35% wet darkening. A SurfaceAppearance's ColorMap normally overrides the part colour. Options, in order of preference:
1. **Tint-mask mode with `SurfaceAppearance.Color`** *(verify availability)*. Author a neutral-value ColorMap. The code multiplies the SurfaceAppearance colour instead of the part colour; this is a small change in `applyWetness` and `shell`.
2. **`AlphaMode = Overlay`.**
   - Paint the base fabric areas with **low alpha (0.15–0.35)**, so `MeshPart.Color` (tint and wet darkening) dominates there.
   - Paint dirt, wear, hardware, webbing and seams with **high alpha (0.8–1.0)**, so they keep their own colour.
   - The normal and roughness maps still carry all the fabric structure.
   - This works with today's code unchanged.
3. Bake per-item ColorMaps and a wet variant swapped by reparenting. This is the most memory and the least flexible; use it only if 1 and 2 fail.

Whichever is chosen, the roughness change on wetting needs option 3's reparenting (roughness is not script-tintable).

### 5.4 CollisionFidelity choices
| Setting | Use for |
|---|---|
| `Box` | All welded cosmetics (they do not collide anyway; minimal data), stakes, posts, crates, simple colliders |
| `Hull` | Small and medium convex rocks, fire-ring stones, logs, tree trunks |
| `Default` | Medium props with mild concavity where the exact fit does not matter |
| `PreciseConvexDecomposition` | Climbable cliff and ice meshes (climbing and placement raycasts hit collision geometry), large walkable rock. **Not** hollow shells (tents): convex pieces fill the interior, so use invisible Part colliders instead. |

### 5.5 RenderFidelity and LOD
- `Automatic` for almost everything: Roblox decimates with distance. `Precise` only for the held ice axe (always near the camera). `Performance` for small scatter rocks.
- Authored LOD1 and LOD2 meshes in this document serve two purposes: as the decimation target that `Automatic` should resemble (art review), and as swap meshes for trees and large world props, switched by a client-side distance script.
- We are not aware of a way to author custom LODs on one MeshPart *(verify)*. `Model.LevelOfDetail = StreamingMesh` gives engine-generated far representations under StreamingEnabled *(verify quality, especially on alpha foliage)*.
- The per-mesh import limit is currently 20,000 triangles *(verify)*. Every budget here is far below it.

### 5.6 Welded cosmetic gear
Everything mounted by `EquipmentService` must be:
- `Anchored = false`, `Massless = true`, `CanCollide = false`, `CanQuery = false`, `CanTouch = false` (as `AssetFactory.weldCosmetic` does);
- welded with `WeldConstraint` **after** its final CFrame is set (see the comment in `EquipmentService.shell`).

Also:
- `CastShadow = false` on parts smaller than about 0.3 studs (buckles, pulls, rivets, carabiners).
- If fluid or aerodynamic forces are enabled in the place, set `EnableFluidForces = false` on cosmetics *(verify property availability)*.
- Never add a Humanoid-affecting mass or a collider to gear.
- **Layered clothing** (`WrapLayer` on accessories) is a possible future replacement for per-part shells, giving clothing that deforms across R15 joints. It needs inner and outer cages authored to Roblox's cage spec and a rewrite of `EquipmentService`'s shell scheme *(verify current requirements)*. Until then, author per-part shells with 0.06-stud joint overlaps.

### 5.7 MaterialVariant for terrain and parts
- `MaterialVariant` instances live under `MaterialService`. Each has a `BaseMaterial`, ColorMap / NormalMap / RoughnessMap / MetalnessMap, `StudsPerTile`, and `Pattern` (`Regular` or `Organic`; Organic reduces visible tiling).
- Terrain uses a variant only through a **base-material override** on `MaterialService` (one override per base material, place-wide). That is why section 3.3 maps snow states onto distinct base materials.
- Parts can name a variant directly through `BasePart.MaterialVariant`. How MaterialVariants map onto MeshPart UVs versus world-space tiling should be checked before using them on props *(verify)*.
- Prefer SurfaceAppearance for props and MaterialVariant for terrain and large architectural Parts.

### 5.8 Budgets and memory
- One fully kitted character ≤ 18,000 tris and ≤ 10 SurfaceAppearances. Share atlases: the webbing and hardware trim alone serves about 8 assets.
- Unique 1024² SurfaceAppearances are the main memory cost on mobile. Keep **≤ 40 unique 1024² sets** in memory in a typical streamed area.
- Transparent surfaces (needles, flag fringes, ice shells) cost sorting and overdraw. Keep them small, and never stack several transparent layers in view at once.
- Shadow-casting `PointLight`s: limit them to the nearest one or two (campfire). Turn others to `Shadows = false`.

---

## 6. Code follow-ups found while writing these specs

These are problems in the current greybox, or code changes that the meshes need. The art in this document assumes the "Fix" column; until the fix lands, artists should match the greybox and flag it.

| # | Where | Problem | Fix |
|---|---|---|---|
| 6.1 | `AssetFactory.backpack` | The `AxeLoop` and `DaisyChain` are at x = 0, but the `Axe` anchor puts the axe at x = +0.22 w, so the axe head is not in the loop. | Move `AxeLoop` to x = +0.22 w (and add a mirror loop at −0.22 w). Add a shaft keeper 1.1–1.2 studs above it. |
| 6.2 | `AssetFactory.backpack` / `ropeCoil` | The coil is 0.84 studs wide; the lid straps at ±0.28 w (0.81–1.04 apart) miss it, so nothing holds the rope. The straps also cannot be both flat and over a coil. | Widen the coil to 1.15. Ship `LidStraps_Flat` and `LidStraps_OverCoil`, and toggle them by rope stowed state in `EquipmentService.build`. |
| 6.3 | `AssetFactory.woodBundle` | The bundle straps at ±0.35 do not coincide with the pack's side compression straps (+0.17 h and −0.03 h relative to the Wood anchor; tier-dependent). | Pass the tier height into `woodBundle`, or return strap heights as anchors. |
| 6.4 | `EquipmentService` `SLOT_PARTS.Boots` | Boots cover the feet only; a mountaineering boot rises up the shin. | Add cuff shells on `LeftLowerLeg` / `RightLowerLeg` for `alpine_boots`, and have the pant shells overlap them. |
| 6.5 | `AssetFactory.windWall` | Logs are spaced 0.714 apart at Ø 0.62, leaving 0.09-stud gaps (floating logs). Logs end 0.2 short of the posts, and one post per end cannot hold a stack. | 8 logs stacked in contact, a pair of posts at each end (z = ±0.4), and top lashings. |
| 6.6 | `AssetFactory.trailMarker` | `Flag` uses `Neon` (fabric is not emissive). | Use Fabric or a SurfaceAppearance; the BillboardGui and PointLight already provide fog visibility. |
| 6.7 | `AssetFactory.campfire` | `PointLight.Shadows = true` on every fire; nothing collides, so players can stand in the fire. | Limit shadowed fire lights by distance; make the ring stones collide (Hull). |
| 6.8 | `EquipmentService.applyWetness` / `shell` | They write `BasePart.Color`, which a SurfaceAppearance ColorMap overrides unless Overlay alpha or tint-mask mode is used. | Follow 5.3 (option 1 needs a small code change; option 2 needs none). |
| 6.9 | `EquipmentService`, `BuildingService` | `SnowCap` is found with `FindFirstChild` and `RoofSnow` with `GetChildren`: both must be **direct children** of the model. | Keep these meshes as direct children in the templates. |
| 6.10 | `AssetFactory.pineTree` / `rock` | `Bough` uses `Grass` material and the snow parts use `Snow` Part material; mesh replacements will use SurfaceAppearance. | Clone tree and rock templates per band and family (3.1, 3.2). |
| 6.11 | All builders | Runtime `Instance.new` cannot produce art meshes. | Clone templates (5.1); keep greybox as the fallback. |

