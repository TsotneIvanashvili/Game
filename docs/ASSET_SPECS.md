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

