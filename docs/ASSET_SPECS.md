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

**GAME PURPOSE** — The highest torso insulation (Torso 6, Head 1). Insulation ≥ 0 at the head triggers the `Hood` part.

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
  - Merino: fine jersey knit (normal at ≈ 0.01-stud pitch), flatlock seams, a thumb-loop cuff on the long sleeves (Merino covers UpperArm only in code).
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

