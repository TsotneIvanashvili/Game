# Art Direction v2: Stylized Polar Expedition

Supersedes the "realism" direction in the original brief and in ASSET_SPECS.md for **look**.
ASSET_SPECS.md still applies to **construction logic** (straps attach, poles hold up tents,
nothing floats), just rendered in this style.

Reference: the user's target screenshots (a popular Roblox polar-expedition game). We match
the *style and readability*, never its name, logo, branding text ("SP"), or exact buildings.

## 1. Look in one sentence
Bright, clean, chunky: saturated solid colours on smooth plastic, big readable silhouettes,
white snow everywhere, teal glacier ice on every steep face, colourful tents as landmarks.

## 2. Materials
- Props and gear: `SmoothPlastic` by default. `Fabric` only for big tent skins and carpets,
  `WoodPlanks`/`Wood` for crates, planks and poles, `Metal` for ladders and railings.
- No `Neon` except small light sources (lamp bulbs, beacon tips).
- Terrain: only `Snow` (anything walkable) and `Glacier` (any slope steeper than about 40°,
  crevasse walls, ice cliffs). `Rock`/`Slate` only for rare dark outcrops near the summit.
  There is no grass, dirt, mud or water anywhere. The world is always snow.

## 3. Palette (Color3.fromRGB)
| Role | Colour |
|---|---|
| Snow (terrain colour) | 236, 242, 250 |
| Glacier ice (terrain colour) | 92, 205, 214 |
| Tent yellow | 245, 200, 40 |
| Tent blue | 40, 120, 220 |
| Tent red | 210, 45, 45 |
| Tent purple | 120, 60, 180 |
| Tent orange | 235, 110, 30 |
| Rescue orange (station) | 235, 95, 35 |
| Crate wood | 214, 180, 120 |
| Pole / rope brown | 120, 85, 55 |
| Marker red / white | 220, 40, 40 / 245, 245, 245 |
| Checkpoint green | 40, 220, 60 |
| UI blue (panels, buttons) | 0, 110, 200 |
| UI dark blue (insets) | 0, 70, 140 |
| UI text | 255, 255, 255 |
| UI accent cyan | 0, 230, 255 |
| UI warning orange | 255, 100, 20 |

## 4. Shapes
- Big shapes first: a tent reads as a tent from 200 studs away. Detail is secondary.
- Bevel-ish chunkiness: thick parts (≥ 0.3 studs) rather than paper-thin ones.
- Tents: A-frame (two sloped skins + end walls built from wedges) and dome/tunnel shapes. Each
  has a darker door panel, a window, a pole tip poking out of the top, and guy lines running
  to stakes. Sizes vary: 2-person (8x6x7 studs), group tent (14x9x10), big mess/equipment tent
  (40x14x28, walk-in, with interior).
- Crates: wood planks with visible slats, stacked in 2s and 3s, some with supplies on top.

## 5. Base camp composition (landmarks)
A flat snow basin enclosed by high snow/ice mountains on every side (no void, no visible floor).
- **Equipment tent** (big yellow, walk-in): carpet floor (dark blue Fabric), a back wall with
  an "EQUIPMENT" banner (dark navy bar, white bold text via SurfaceGui), mannequin stands showing
  jackets, packs, helmets and boots. The outfitter prompt lives here.
- **Sleeping tent** (yellow or blue, walk-in): a row of blue sleeping mats with white pillows.
  Each mat has a "Sleep" prompt (rest = big fatigue recovery, camp healing).
- **Rescue station**: a stilted orange building with a white stripe, cyan windows, a red cross,
  stairs and railings, and a lookout tower. This is where evacuated players wake up.
- **Supply area**: crates, a supply crate prompt, flag poles with coloured flags, lamp posts.
- **Campfire**: a stone ring, a log teepee and a big flame. It's the social centre.
- Ring of 6-10 small coloured tents with guy lines.

## 6. Route and mountain language
- The route is long and vertical: base camp → Camp 1 → Camp 2 → Summit, each camp a smaller
  version of base camp (2-4 tents, fire, supply crate, checkpoint ring).
- Crevasses are crossed by **rope bridges**: wooden planks on two rope rails between posts
  and anchors, sagging slightly in the middle.
- Ice walls are climbed by **aluminium ladders** (TrussPart-based so Roblox climbing works),
  or by our climbing system on Glacier faces with an ice axe.
- **Route markers**: thin red/white striped poles with small red flags every ~40 studs, so
  players can navigate in a whiteout.
- **Signs**: yellow triangle warning signs ("HIGH WINDS", "CREVASSES", "AVALANCHE RISK") on posts.
- Rope handrail fences (posts + sagging rope) on exposed ledges.

## 7. Checkpoints
A flat bright-green ring (about 10 studs across) on the snow, with a floating green
"Checkpoint" label (BillboardGui, bold font). Standing in the ring signs you in.
Camp names float above the camp in cyan bold text ("Camp 1").

## 8. Characters and gear (part-built accessories, chunky)
- Jacket: bold red or blue body shells, ribbed cuffs (slightly darker band at the wrists), a fur
  hood ring (tan, rough-looking) around the neck, a zipper line, a chest logo patch (a generic
  mountain icon, never a real brand).
- Pants: black shells.
- Boots: chunky navy shells with a lighter stripe and visible crampon spikes under the sole.
- Helmet: a blue dome on the head with a small headlamp on the front (SpotLight when the
  Light toggle is on).
- Goggles: white rim with a cyan lens band across the eyes.
- Mask: a dark knit face cover.
- Backpack: navy body, lighter top roll, two vertical strap rails with buckles; tier changes
  the size.
- Players can toggle head items (helmet, mask, goggles, light) from a gear menu.

## 9. UI language
- Font: `Enum.Font.FredokaOne` (bold, rounded) for everything big; `GothamBold` for small text.
- Panels: solid UI blue with a thick white outline (UIStroke 4-6 px), large corner radius (16+).
- Buttons: round icon buttons on the left edge (white glyph on blue circle, white stroke).
- Top centre: compass heading in a blue tab ("North", "South-West"), clock under it ("2:30 PM").
- Right: info card with altitude (cyan number), a mountain glyph, temperature °C and °F, and a
  weather glyph (sun / cloud / snow / storm).
- Bottom right: big stat row: heart (health %), water drop (thirst %), lightning (energy %),
  thermometer (warmth %).
- Bottom centre: a hotbar of 3-5 quick slots (water bottle, food, map...).
- Event banner: an orange pill at top centre ("A storm has arrived. Be careful!").
- Title screen: big logo text, then Play / How to play / Gear buttons in UI blue.

## 10. Weather and atmosphere
- Always snowing at least lightly; wind-blown snow streaks near ridges.
- A day/night cycle (about 20 real minutes per day); nights are colder and bluer.
- Storm = whiteout: Atmosphere density near max, bright grey-white fog colour, heavy snow,
  orange banner, much colder.
- Footprints in snow behind players (client-side, fade after about 20 s).
- Breath vapour, a warm orange glow around fires, and lamp light at camps at night.

## 11. Performance budget
- Base camp at most about 2,500 parts total; small camps at most 600 each.
- Anything decorative: CanCollide=false, CanQuery=false, CanTouch=false, CastShadow only on big shapes.
- Prefer one big part over many tiny ones; reuse builders.
