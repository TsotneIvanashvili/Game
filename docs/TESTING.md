# Testing

This document covers how the mountain-survival expedition is verified:

1. [Automated checks](#1-automated-checks) (run on any machine, no Roblox needed)
2. [Manual Studio test plan](#2-manual-studio-test-plan) for the route
3. [Multiplayer matrix](#3-multiplayer-matrix)
4. [Edge cases and exploit tests](#4-edge-cases-and-exploit-tests)
5. [Performance checklist](#5-performance-checklist)
6. [Bug report template](#6-bug-report-template)

> **Status:** none of the manual cases below have been run in Roblox Studio yet. The
> "Expected" columns describe what the code is written to do, worked out from reading the
> source (numbers come from `src/shared/Config/*`). The first Studio pass will check those
> expectations. When behaviour and this document disagree, file a bug (template in
> section 6). Do not edit the expectation to match the behaviour.

---

## 1. Automated checks

### 1.1 What `tests/check.sh` does

`tests/check.sh` is the full local gate. It runs four stages in order and stops at the first one
that fails (`set -e`):

| Stage | Command | What it catches |
|---|---|---|
| **Compile** | `luaurun tests/compile_check.luau <file>` for every `*.luau` under `src/` and `tests/` | Loads each file with the **real Luau compiler** (vendored by `mlua`). Catches syntax that StyLua accepts but Roblox rejects, such as ambiguous call syntax across lines, bad `if`-expressions or a stray `continue`. It only compiles: it does not run or type-check the file. Errors print as `COMPILE ERROR: <file>` followed by the compiler message. |
| **Lint** | `selene src tests` | `selene.toml` uses `std = "roblox_lite"` (`roblox_lite.yml`), a small hand-written Roblox std that works offline. It declares the Roblox globals (`game`, `workspace`, `Instance`, `Vector3`, `task`, `Enum`, ...) as `any`, plus the test-host globals `__loadfile` and `ROOT`. It catches undefined globals, unused variables, unreachable code and similar. **It cannot catch misspelled Roblox API members**, because every Roblox global is `any`; the boot test (1.5) catches those for code it runs. `shadowing` and `multiple_statements` are allowed. |
| **Format** | `stylua --check src tests` | Formatting against `stylua.toml`: tabs, 120 columns, Unix line endings, double quotes, parentheses always. Run `stylua src tests` to fix. |
| **Suites** | `tests/run.sh` | Runs every `tests/spec*.luau` in turn with `luaurun <spec> <repo root>`: `spec.luau` (unit/stress, 1.3), `spec_terrain.luau` (terrain and layout, 1.4), `spec_boot.luau` (headless boot and play simulation, 1.5). Each prints `N passed, M failed` and raises an error on any failure, so the script exits non-zero. |

```sh
tests/check.sh          # everything
tests/run.sh            # the three suites only
luaurun tests/spec.luau .            # one suite, from the repo root
luaurun tests/spec_terrain.luau .
luaurun tests/spec_boot.luau .
```

Prerequisites on `PATH`: `luaurun` (1.2), `selene` and `stylua`. The repo pins tool versions in
`rokit.toml` (`rokit install`): selene 0.27.1, stylua 2.0.2, rojo 7.4.4. Newer local versions
usually agree, but a StyLua version bump can reformat code; pre-merge checks should use the pinned
versions.

A clean run prints `compile: ok`, selene's `0 errors / 0 warnings / 0 parse errors`, and then
`== spec.luau`, `== spec_terrain.luau`, `== spec_boot.luau`, each ending in `N passed, 0 failed`.
The boot suite is the slow one: it runs several minutes of virtual time and builds the full
world in the emulation.

### 1.2 `luaurun`

`luaurun` is a very small Luau host written in Rust on top of the [`mlua`](https://crates.io/crates/mlua)
crate. The `luau` and `vendored` features compile Luau from source, so no system Lua is needed.
The host does three things:

* loads and runs the script given as the first argument,
* exposes `__loadfile(path)`, which compiles a file and returns it as a function without running
  it (the harness and the mock use it to implement `require`, and `compile_check.luau` uses it to
  compile-check a file),
* sets a global `ROOT` to the second argument (default `"."`).

**Requirements:** a Rust toolchain (any recent stable) and a C++ compiler (`g++` or `clang++`),
because `luau0-src` builds the Luau VM and compiler from C++ source. The first build takes
about a minute.

```sh
mkdir -p luaurun/src && cd luaurun
# write Cargo.toml and src/main.rs as below, then:
cargo build --release
cp target/release/luaurun ~/.cargo/bin/      # or: cargo install --path .
```

`Cargo.toml`:

```toml
[package]
name = "luaurun"
version = "0.1.0"
edition = "2021"

[dependencies]
mlua = { version = "0.10", features = ["luau", "vendored"] }
```

`src/main.rs`:

```rust
use mlua::{Lua, Result};
use std::env;
use std::fs;

// Tiny Luau host for running tests outside Roblox.
// usage: luaurun <script.luau> [root]
fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let path = &args[1];
    let src = fs::read_to_string(path).expect("read script");
    let lua = Lua::new();
    let load = lua.create_function(|lua, p: String| {
        let s = fs::read_to_string(&p).map_err(mlua::Error::external)?;
        lua.load(s).set_name(p).into_function()
    })?;
    lua.globals().set("__loadfile", load)?;
    lua.globals().set("ROOT", args.get(2).cloned().unwrap_or_else(|| ".".to_string()))?;
    lua.load(src).set_name(path.as_str()).exec()
}
```

It panics without arguments; that is expected. Versions resolved in the reference build:
`mlua 0.10.5`, `mlua-sys 0.6.8`, `luau0-src 0.12.3+luau663`.

### 1.3 Unit / stress suite (`tests/spec.luau`)

`tests/harness.luau` builds a fake `script` instance tree mapped onto the filesystem, so
`require(script.Parent.X)` inside shared modules resolves to `src/shared/.../X.luau`. It also stubs
the two Roblox datatypes the config modules build at load time (`Vector3.new` with
`+`/`-`/`Magnitude`, and `Color3.new`/`fromRGB`). About 50 tests:

| Area | What is covered |
|---|---|
| **Config integrity** | Every item def is well formed. Loadout, outfitter and supply tables only reference real items. Recipes reference real items, and every implemented recipe can be built from items the game provides. The weather graph is connected. Zones are ordered top-down. Rank lookup. |
| **Warmth** (`WarmthModel`) | Layering rules (insulation stacks, best wind/water protection, worst wet penalty). Comfort, frostnip and light-snow timings. Sweating when overdressed, not by a fire. Expedition gear in a blizzard. A fire rescues a freezing player in under a minute. Fire heat falloff. Wetting and drying. |
| **Stamina / survival** (`SurvivalModel`) | Sprint drain and lockout, regen delay, every regen modifier, max-stamina penalties, weight effects, oxygen floor, starvation/dehydration damage with no NaN over a long run, hypothermia knock-out, frostbite stages, hand warmer, hot food. |
| **Injuries** (`InjuryModel`) | `useWouldHelp`, broken leg rules, camp-rest healing, bandages, serialization. |
| **Inventory** (`InventoryModel`) | Merging, slot limits, partial adds, containers, snapshot isolation, atomic removal, clamped removal. **Stress:** 10,000 random operations keep slot limits, quantity bounds, unique uids and non-negative weight. |
| **Weather** (`WeatherModel`) | Forced storm path from Clear walks every intermediate state; blending; `pickNext` only returns neighbours; always snow, colder with altitude and at night; time-of-day offset is continuous. |
| **Climate per camp** | With an inline starter suit and upgraded suit: comfortable at Base Camp in Clear; a Base Camp storm gives frostbite in about 3-6 minutes; the starter suit lasts 10+ minutes at Camp 1; upgrades make Camp 2 comfortable and a clear summit push possible; a summit blizzard is deadly even in upgraded gear. |

### 1.4 Terrain and layout suite (`tests/spec_terrain.luau`)

Builds `TerrainModel.new(WorldLayout)` once in the plain VM (same code the server runs) and checks
the world as data, about 28 tests:

* the heightfield covers `Bounds` on the 4-stud grid, builds quickly, stays within the 12M solid
  voxel budget, and Base Camp is in the first build phase;
* materials: snow on gentle columns, Glacier on steep faces, a little Rock near the summit only;
* natural slopes everywhere except the designed cliffs; the ice wall is a real cliff and only the
  bypass ramp climbs it; Base Camp is enclosed by mountains except along the trail; backdrop
  peaks stand outside the terrain within Part size limits;
* camps sit on the surface at their planned heights on flat footprints big enough for the kit;
* the route visits Base Camp, Camp 1, Camp 2 and the summit in order, is long enough for a
  15-25 minute climb, every walked segment follows the surface with no step above jump height
  and is 35 degrees or gentler; bridges span real gaps; ladders climb real walls; the ice-wall
  walk-round is continuous;
* markers every ~40 studs on the surface; fences, ropes and signs reference real route points;
  wood is scarce and on level ground; trees only near Base Camp; rockfall zones cover the trail
  and release from above it; the summit is a small flat top with the `SectionEnd` on it;
* model queries are fast enough for prop placement.

### 1.5 Headless boot test (`tests/spec_boot.luau` + `tests/mock/`)

`tests/mock/` is a headless Roblox emulation for `luaurun`: a virtual-time scheduler with
Deferred signal semantics, Roblox datatypes with engine maths (`datatypes.luau`), strict enums
(`enum.luau`), an instance system whose class catalog (`classes.luau`) errors on unknown members
exactly like the engine, services (`services.luau`: Players with an R15-like rig, RunService,
CollectionService, DataStoreService, TweenService, input services, ...), remote bridging with
network-style argument copying (`network.luau`), a world with raycasts, overlap queries, welded
assemblies and a kinematic humanoid controller (`world.luau`), and a loader that mirrors the Rojo
mapping (`loader.luau`). One server context and any number of client contexts share one instance
tree; client-created instances are client-only and client writes to server instances are local
overlays. **Not emulated:** rigid-body physics for loose parts, Touched events, terrain voxels
(the test injects `TerrainModel.heightAt` as the ground surface), rendering, sound and
animation.

`spec_boot.luau` runs the **real** `src/server/init.server.luau` and, per player,
`src/client/init.client.luau`, then drives play through the real remotes, prompts and UI
(about 34 steps): world build and `[Report]` counts, two players joining, title screen, HUD,
gear, survival attributes, inventory use, gear toggles, sprint, building a campfire, checkpoint
rings, downed/revive/carry/give up, walking (teleporting) the route to the summit summary,
outfitter and supply panels, gathering, tents and wind walls, drop/give/treat, pings, climbing,
fall damage, forced rockfall, forced storm, respawn after death, a DataStore outage, carrier
disconnect, rejoin within the grace window, and BindToClose saves.

Any runtime error in any server or client thread, and any `warn()` not in the test's allow-list,
fails the step it happened in. This is what catches nil indexing, calls to members that don't
exist, wrong argument shapes and broken cross-service flows that compile and lint can't see. A
green boot test still says nothing about physics feel, replication timing, streaming, real
terrain voxels or how anything looks.

### 1.6 Preview renderer (`tests/render/`)

An approximate offline renderer so the generated world can be looked at without Studio. The
images in `docs/previews/` come from it; they are **not** Roblox screenshots (no Roblox
lighting, textures, particles or UI). See `docs/previews/README.md` for what each image shows.

* `tests/render/dump.luau` runs the real `WorldBuilder.build()` (with `CampKit`, `RouteKit`,
  `AssetFactory`) and `EquipmentService.refresh()` on a dummy in the default loadout, inside the
  lightweight mock `tests/render/RobloxMock.luau`, and prints every part, text label, light, camp,
  route point and a 2-stud `TerrainModel` height grid.
* `tests/render/terrain.py` meshes that heightfield (two triangles per cell, smooth normals, top
  material on gentle triangles and the body material on cliff faces).
* `tests/render/render.py` rasterises everything with a numpy z-buffer (sun with shadow maps,
  ambient, point lights, haze, 2x2 supersampling, SurfaceGui/BillboardGui text).
* `tests/render/checks.py` prints geometry diagnostics from the same dump: floating parts, parts
  buried under the terrain, clashes between models, camp footprint overlaps, route steps.

Needs `luaurun`, Python 3, numpy and Pillow.

```sh
python3 tests/render/render.py                        # all presets -> docs/previews/ (several minutes)
python3 tests/render/render.py camp1 summit           # just these presets
python3 tests/render/render.py --list                 # preset names
python3 tests/render/render.py --size 640x360 --ss 1 --out "$TMPDIR/prev"   # fast drafts elsewhere
python3 tests/render/render.py --no-dump camp1        # reuse the last scene dump
python3 tests/render/checks.py                        # geometry diagnostics
```

Intermediate files (scene dump, terrain mesh) go to `$TMPDIR/game-render` (`--work` to change).
Scattered trees and rocks land in different (equally valid) spots than on a real server because
the mock's `Random` is not Roblox's.

### 1.7 What the automated checks cannot cover

Everything below is covered only by the manual plan in sections 2 to 5:

* real physics: humanoid movement on voxel terrain, falls, boulders, carry welds, climbing
  `AlignPosition`, TrussPart ladders, rope-bridge planks, network ownership;
* real terrain: `WriteVoxels` output, smooth-terrain meshing, material look, generation time;
* replication timing, `StreamingEnabled`, latency on climbing and prompts;
* live `DataStoreService` (session locks across servers, throttling);
* everything visual and audible: UI layout on phone and desktop, weather, night, particles;
* performance on real devices.

`Util/Validate.luau` is exercised through the real remotes in the boot test but has no direct
unit tests.

---

## 2. Manual Studio test plan

### 2.0 Setup, conventions and helpers

**Build the place.** Run `rojo serve` and connect the Rojo plugin in an empty place (delete the
template Baseplate and SpawnLocation). Alternatively, `rojo build -o MountainSurvival.rbxl` and
open the file. The server generates the world from `WorldLayout` on start, unless a
`Workspace.Mountain` model already exists. Output should show `[World] terrain ok (...)`,
`[Server] world generated in X.XXs`, `[Server] 15 services started in X.XXs` and a `[Report]`
line in which every count is above zero.

**Pre-flight (blocking).** Before running anything else, confirm all of the following:

* [ ] Output shows **no errors** on Play (server or client), and `[World] terrain ok`.
* [ ] Nobody spawns before the world is built; the first spawn is on the Base Camp spawn pad.
* [ ] `ReplicatedStorage.Remotes` contains the 14 client->server and 9 server->client remotes
      listed in `src/shared/Net/Remotes.luau`. `ReplicatedStorage.WorldState` exists.
* [ ] The title screen appears; after PLAY the HUD is visible (teammates top-left, compass and
      clock top-centre, altitude/temperature card top-right, stat icons bottom-right, hotbar).
* [ ] Every key used below is bound: Tab/I, B, H, M, V, 1-4, C, Shift, Space, G, X, plus E/F/Q on
      prompts.
* [ ] The reset button is disabled (`MovementController` turns it off).

**Conventions**

* Coordinates are `(X, Y, Z)` in studs, taken from `src/shared/Config/WorldLayout.luau` (and
  `CampKit` offsets for camp props). **+Z is uphill**, +Y is up and X is lateral. The layout is
  still being tuned: if a coordinate below is off, re-read `WorldLayout` (route points have ids
  such as `Camp1`, `WallFoot`, `R2`). Ground heights come from the terrain model; add +5 to Y
  when teleporting.
* The HUD altitude is `300 + 4 x Y` metres: Base Camp 300 m, Camp 1 1100 m, Camp 2 2100 m,
  Summit 3500 m.
* Zone by Y: Base Camp Valley < 40, Lower Valley 40-160, Icefall 160-330, Upper Glacier 330-520,
  High Ridge 520-720, Summit >= 720.
* Live state: select your `Player` in Explorer. The **Attributes** section of Properties updates
  live (`Stamina`, `MaxStamina`, `Hunger`, `Thirst`, `Fatigue`, `Oxygen`, `Warmth`,
  `WarmHands`/`WarmFeet`/..., `Wetness`, `ColdLevel`, `Exertion`, `Injuries`, `Zone`,
  `ElevationM`, `TempC`, `WindMs`, `Weather`, `InShelter`, `NearFire`, `CanSprint`, `CanClimb`,
  `ClimbSpeed`, `Climbing`, `Resting`, `Downed`, `BleedOut`, `Carrying`, `CarriedBy`,
  `Checkpoint`, `CheckpointName`, `XP`, `Rank`, `Weight`, `WeightLimit`, `HeldItem`,
  `BuildingUntil`, `GearHelmet`/`GearMask`/`GearGoggles`/`GearLight`). Weather and time live on
  `ReplicatedStorage.WorldState`: `WeatherFrom`, `WeatherTo`, `WeatherBlend`, `WindMs`,
  `WindDirection`, `Precipitation`, `Fog`, `Cloud`, `TempOffsetC`, `ClockTime`.

**Key map:** Tab / I = pack. B = Build Book. H = gear toggles. M = route panel. V = first/third
person. 1-4 = hotbar (water, food, first aid, tool). C = climb grab / let go. W/S/A/D move on the
wall. Space = jump off the wall. Shift = sprint (hold). G = ping. X = set down a carried player.
Prompts use **E** (primary), **F** (secondary) and **Q** (cook/boil/melt). In placement mode: R
rotates, left-click places, right-click / Esc / B cancels.

**Server command-bar helpers.** In Studio Test, switch the view to *Server* and run these in the
command bar:

```lua
-- teleport (replace Player1 / coordinates)
game.Players.Player1.Character:PivotTo(CFrame.new(-150, 205, 1610))
-- low health, so the next hit downs you
game.Players.Player1.Character.Humanoid.Health = 5
-- disconnect a player
game.Players.Player2:Kick("test disconnect")
-- count BaseParts
local n=0 for _,d in workspace:GetDescendants() do if d:IsA("BasePart") then n+=1 end end print(n)
```

> Don't set `Humanoid.Health = 0` from the command bar. That kills the character outright and
> bypasses the downed system (see E-12). Requiring a service ModuleScript from the command bar
> may give you a **separate copy** of the module, because the command bar can use its own
> require cache. Calls such as `DisasterService.forceRockfall()` or
> `WeatherService.force("Storm")` may then do nothing. Check this in 2.10 before relying on any
> service hook. Teleporting far can trip the movement sanity check (snap-back); wait a tick on
> the ground or teleport in short hops if that happens.

**Map landmarks** (from `WorldLayout` and `CampKit`; camps all have yaw 0, so camp offsets are
world offsets from the camp centre)

| Place | Coordinates / extent |
|---|---|
| Base Camp centre / campfire | (0, 0, 0). Camp radius 110. |
| Base Camp spawn pad | (0, 0, −45), 12×12 SpawnLocation |
| Base Camp checkpoint ring / logbook | ring (0, 0, 28), logbook (7.5, 0, 27). Base Camp is checkpoint 1 from the start, so its ring does nothing. |
| Base Camp supply crate "BaseCamp" / meltwater | (−18, 0, 4) / (−14, 0, 13) |
| Equipment tent (outfitter counter inside) | tent centre (−28, 0, −36), 40×28 |
| Sleeping tent (6 sleeping mats) / rescue station | (16, 0, −38) / (46, 0, −8) |
| Wood near Base Camp | ten logs between Z −30 and Z 700 (e.g. (−95, ~0, 110), (124, ~0, −30)); 3-4 wood each, respawn 240 s |
| Valley avalanche slope + `ValleyAvalanche` rockfall zone | slope west of the trail around (−230, 90, 500); zone box centre (10, 25, 500), size (160, 60, 240): X −70…90, Z 380…620. Releases at X −250, Z 440/500/560, push +X |
| Headwall switchbacks | from `HeadwallFoot` up the legs `H1`…`H7` to Camp 1 (Z ≈ 1100–1500) |
| **Camp 1** | centre (−150, 200, 1630), radius 50. Spawn (−150, 200, 1608). Ring (−150, 200, 1615), logbook (−142.5, 200, 1615). Crate "Camp1" (−137, 200, 1623), meltwater (−162, 200, 1622), group tent (2 mats) (−150, 200, 1647). Wood: 3 logs nearby, respawn 420 s |
| Crevasse plateau | surface Y = 200 + 0.06 × (Z − 1700). Crevasses (25–30 wide, 30–32 deep) at Z 1800, 1920, 2040, 2160; rope bridges at X −80, 40, −40, 60 |
| **Ice wall** | south face at Z ≈ 2300, about 48 studs high, top Y 284. Ladder at X 200 (`WallFoot` → `WallTop`). Bypass ramp along its foot to the west end at X −200 |
| Glacier switchbacks + `SeracFall` zone | legs `T1`…`T6` (Y 330–446); serac band above the `T4`→`T5` leg (T4 (276, 390, 2666), T5 (−230, 438, 2800)); zone box centred on that leg, size (240, 60, 100) |
| **Camp 2** | centre (−200, 450, 3030), radius 50. Spawn (−200, 450, 3008). Ring (−200, 450, 3015), logbook (−192.5, 450, 3015). Crate "Camp2" (−187, 450, 3023), meltwater (−212, 450, 3022). Woodpile (−290, ~450, 3060): 8 wood, never respawns |
| Ridge | `RidgeStart` (0, 450, 3100) → `R1` (−160, 520, 3380) → notch bridge → `R2` (60, 590, 3645) → ice-step ladder to (60, 618, 3654) → `R3` → `R4` (20, 755, 4060) |
| **Summit / SectionEnd** | (0, 800, 4160), radius 16; flag and cairn |
| Safety net | Below Y −30 you are recovered to your checkpoint after 3 s. Invisible safety floor at Y −120; the snow skirt (flat Snow Parts) surrounds the terrain at Y ≈ 0 |

**Baseline loadout weight.** A new player wears the default suit (merino base, red expedition
parka, black insulated pants, expedition boots and gloves, helmet with headlamp, knit mask,
goggles: 4.5 kg) with the medium pack (1.4 kg, 14 slots, 18 kg limit) holding the starter pack
(1 L treated water, empty thermos, 3 energy bars, chocolate, 2 hand warmers, bandage, lighter,
ice axe: 2.6 kg). Total about **8.6 kg** (worn clothing and the pack itself count). The hard cap
is 130% of the limit, **23.4 kg**. Wood weighs 1.2 kg, rope 2.5 kg, a tarp 1.1 kg, a tent pack
3.2 kg.

---

### 2.1 Spawn & loadout

| ID | Setup | Steps | Expected |
|---|---|---|---|
| SP-01 | Fresh profile (API access off, or a new test account) | Press Play, then PLAY on the title screen. | You spawn on the plank pad at about (0, 0, −45). The HUD shows Base Camp Valley and 300 m. The weight readout shows about `8.6 / 18 kg`. |
| SP-02 | — | Open the pack (Tab, then I). | Worn: the eight default items above. Contents: water bottle `1000 / 1000 ml · treated`, thermos (empty), energy bar ×3, chocolate, hand warmer ×2, bandage, lighter, ice axe. Slots `/14`. Tab and I both toggle the panel. Hotbar 1-4 shows water, food, first aid, ice axe. |
| SP-03 | — | Walk into the equipment tent and press **E** "Change gear" at the counter. | The outfitter panel opens with 34 stock items grouped by slot. Rank-locked items (down suit top, overboots, heated gloves at rank 2; storm goggles, expedition pack at rank 3) are refused with "Requires a higher rank." Walking more than 14 studs away closes the panel. |
| SP-04 | At outfitter | Take a tent, then try the ice axe, lighter, thermos and water bottle. | The tent pack is given once; a second take gives "You already took one this expedition." The ice axe, lighter, thermos and water bottle are refused the same way, because the starter pack counts as taking them. |
| SP-05 | At outfitter | Pick *Insulated parka*, then *Pack (large)*. | The parka is worn at once (the old jacket is not added to the pack). The pack switches; `WeightLimit` becomes 25 and slots 18. The character visuals update (see 2.4). |
| SP-06 | At outfitter, pack holding 11+ stacks | Try to switch to the small daypack. | "Too many items for that pack. Drop some first." If the stacks fit but the weight exceeds 12 × 1.3 kg: "That pack can't carry what you have." |
| SP-07 | At the Base Camp crate (−18, 0, 4) | Press **E** "Open supply crate" and take items repeatedly. | Remaining counts: energy bar 4, chocolate 2, trail mix 2, dried meat 2, canned stew 2, emergency ration 1, electrolyte 1, bandage 3, splint 1, first aid kit 1, hand warmer 3, purification tabs 4, rope 2, tarp 1. Past the allowance: "You've taken your share of that." Full pack or weight cap: "No room in your pack (or too heavy)". Per player, per expedition, not reset by respawning. The Camp 1 and Camp 2 crates have their own smaller tables. |
| SP-08 | Far from any crate | (Exploit check, see X-07) | — |

### 2.2 Survival stats

| ID | Setup | Steps | Expected |
|---|---|---|---|
| SV-01 Stamina drain | Base Camp, flat ground | Hold **Shift** and run. | `Exertion` = `sprint`, speed rises from 14 to 22 studs/s and the FOV widens slightly. Stamina drains at about 11/s. Food and water drain faster: 2.2× sprinting versus 1.2× walking. |
| SV-02 Lockout | Continue SV-01 | Keep holding Shift after Stamina reaches 0. | "You're out of breath." once (15 s cooldown). You drop to walking speed. `CanSprint` and `CanClimb` = false until Stamina recovers to **25**. Regen starts 1 s after you stop spending, at about 14/s. |
| SV-03 Jump cost | — | Jump repeatedly. | Each jump costs 9 stamina. Below 9 stamina, `JumpHeight` is 0. |
| SV-04 Cold at Base Camp | Default suit, Clear, daytime | Stand idle away from fires for 10 minutes. | `TempC` about −10 °C at midday (colder at night, up to −16 °C). No frostbite (a climate test asserts the starter suit is comfortable here in Clear). Hands and feet cool fastest. |
| SV-05 Cold in a storm | Base Camp or Camp 1 during a Storm (WX-02), default suit, outside any shelter | Stand still away from fires. | `Weather` = *Blizzard*, `TempC` about −22 °C at Base Camp and −27 °C at Camp 1 by day. Frostnip within about 3-6 minutes at Base Camp, then Severe and Critical warnings. At Critical warmth (< 12) you take 0.6 HP/s, `CanClimb`/`CanSprint` turn off, and after 20 s at Critical you are **downed by hypothermia** (see 2.11). |
| SV-06 Night | Any camp, Clear | Watch `TempC` and `ClockTime` through a night (a day lasts 20 minutes; the server starts at 09:00). | Temperature falls smoothly after 16:00 to 6 °C below the daytime value between 00:00 and 05:00, and recovers by 11:00. The sky darkens; camp fires and lamps glow stronger. |
| SV-07 Snow wetness | Outside in Light/Heavy Snow | Watch `Wetness`. | Wetness rises slowly (snow gain 0.003/s at full precipitation, reduced by waterproof layers). Stepping into a tent or camp building (`InShelter` = true) stops the gain and you dry slowly; a fire dries you fast. |
| SV-08 Sweating | Base Camp, Clear, insulated parka or down suit worn | Sprint or walk continuously for 2 minutes, away from fires. | Wetness rises from the inside if torso felt temperature exceeds 30 °C. Standing still stops it. Standing by a fire does **not** cause sweating. |
| SV-09 Hunger/thirst | — | Watch Food and Water over 5 minutes of walking. | Hunger drains in about 30 min idle and thirst in about 22 min idle, faster with exertion and altitude. At < 25: "You're very thirsty." / "You're hungry..." (60 s cooldown) and slower stamina regen. At 0 you lose health over time. |
| SV-10 Natural healing | Health < 100, Food and Water > 50 | Stand still, then rest by a fire (E). Then repeat with Food or Water < 50. | Health regenerates at 0.15 HP/s, or 4× while resting. With Food or Water ≤ 50 there is **no** regen. There is no `Health` Script under the character. |
| SV-11 Oxygen and altitude | Ridge and summit | Watch the Oxygen stat and `AltitudeSickness`. | Oxygen starts to fall above 2500 m (Y 550, on the ridge) and is about 88 at the summit; the Oxygen stat appears once it is below 97. Altitude sickness builds above 3000 m (Y 675) unless resting. Note: the "LOW OXYGEN" warning (below 80) cannot fire with current numbers. |

### 2.3 Inventory

| ID | Setup | Steps | Expected |
|---|---|---|---|
| IN-01 Use food | Hunger < 100 | Pack → energy bar → **Use** (or hotbar 2). | Hunger rises, the stack decrements, `itemsConsumed` increments (seen in the summary). |
| IN-02 Pointless use | No injuries, full health | Use a splint. | "That wouldn't help right now." The item is **not** consumed. |
| IN-03 Drink treated | Bottle with treated water | Use (Drink) the bottle (or hotbar 1). | 250 ml per sip. The bottle line updates (`750 / 1000 ml · treated`). An empty bottle gives "... is empty." |
| IN-04 Meltwater | Empty bottle, at a camp's meltwater station | **E** "Fill bottles" (hold 1 s), then **F** "Drink" (hold 0.5 s). | "Filled X L." Water is treated (the station is `Treated = true`). Drinking from the station gives +20 thirst and never causes Stomach Upset. |
| IN-05 Untreated water | Only on a hand-built map with an untreated `WaterSource` | Fill, then drink. Top up a half-full treated bottle. | Fill toast ends "Treat or boil it before drinking." Each sip has a **35%** chance of *Stomach Upset*. Mixing contaminates the whole bottle. (The generated world has no untreated water.) |
| IN-06 Purify | Untreated water in the pack (IN-05), purification tabs | Use the tabs. | One tab is consumed and one container becomes treated. With no untreated water nothing is consumed. |
| IN-07 Give | 2 players within 10 studs | P1: select an energy bar → **Give P2**. | The Give button only lists teammates within 10 studs. One unit moves per click for stackables, the whole item for bottles. If P2's pack is full or too heavy, P1 keeps the item. |
| IN-08 Give out of range | P2 walks away during the click | Click Give after P2 is 11+ studs away. | "Get closer to P2." and nothing moves. |
| IN-09 Treat teammate | P2 has *Bleeding* (rockfall, see RF-03) or a *Sprained Ankle* (fall). P1 has a bandage or splint. | P1: bandage → **Treat P2**. | The injury is removed or marked splinted in P2's HUD. If P2 doesn't need it: "P2 doesn't need that." and nothing is consumed. |
| IN-10 Drop / pick up | — | Drop 1 energy bar, then a whole stack. Pick both up again (**E**). | A small bundle appears on the ground in front of you (not floating). Pick-up takes a 0.3 s hold for small bundles and 1.5 s for big ones (3+ stacks or an evacuated pack). Unclaimed bundles despawn after 10 minutes. |
| IN-11 Overweight | Medium pack, default kit. Gather wood near Base Camp. | Gather one log at a time (E, hold 1.5 s). | About 8 wood (> 18 kg): "Your pack is overloaded. You're slow and tire fast." About 10 wood (ratio > 1.1): sprint blocked. About 11 wood (ratio > 1.15): `CanClimb` = false. The **13th** wood is refused with "Your pack is full or too heavy for more wood." (hard cap 23.4 kg). |
| IN-12 Slot limit | Pack slots full of different stacks | Take a new item type from the crate. | Refused ("No room..."). Existing stacks still merge up to maxStack (energy bar 10, wood 12). |
| IN-13 Wear from pack | Clothing in the pack | Pack → **Wear**. Then click **x** on a worn slot. | The item is worn and the old one goes into the pack. If the pack is full, nothing changes. |
| IN-14 Hold / stow axe | Ice axe in the pack | **Hold** (or hotbar 4), then **Stow**. | `HeldItem` = `ice_axe`, the axe moves from the pack loop to the right hand (EQ-04). Stow reverses it. |

### 2.4 Equipment visuals

Check every visual from the player's own view **and** from a second client, because the visuals
are server-built and must replicate. Compare with `docs/previews/character_*.png` (approximate).

| ID | Steps | Expected |
|---|---|---|
| EQ-01 Pack tiers | At the outfitter, switch small → medium → large → expedition. | Four pack sizes in navy shades, each with harness straps; a **hip belt on Medium and above**. The pack sits on the back and doesn't clip through the torso. |
| EQ-02 Stowed gear | Carry an ice axe (not held), rope, a tarp and wood. | Axe in the pack's loop, rope coil under the top roll, tarp roll under the base, wood bundle on the side in **3 sizes** (1–2, 3–5, 6+). Each disappears when the item leaves the pack. |
| EQ-03 Rebuild only on change | Use energy bars repeatedly. | No flicker of the gear: food doesn't change the visual signature. |
| EQ-04 Held axe | Hold the ice axe. | The axe appears in the **right hand** and vanishes from the pack loop. |
| EQ-05 Clothing | Cycle jackets, pants, gloves and boots at the outfitter. | Jacket shells with cuffs, zipper, chest patch and fur ring; pant shells; gauntlet gloves; chunky boots (crampon style on expedition boots). Works on R15 and R6 avatars. |
| EQ-06 Head gear and toggles | Press **H**. Toggle Helmet, Mask, Goggles and Light. | Each item hides and shows on your character and on other clients. The light needs a helmet with a headlamp ("You need a helmet with a headlamp."); turning it on shows the helmet again. Items you aren't wearing are locked. Hat/hair accessories are hidden under head gear. |
| EQ-07 Wet darkening | Get wet (SV-07). | Fabric shells and the pack darken in steps, up to about 35%, and brighten as you dry. |
| EQ-08 Snow on pack | Stand outside in falling snow. | A snow cap fades in on the pack's top roll; it doesn't build up while `InShelter`, and melts slowly afterwards, faster near a fire. |
| EQ-09 Respawn | Get evacuated (RS-06), or respawn another way. | Gear is rebuilt on the new character about 0.5 s after spawn and again once the appearance loads. No duplicate Gear folders. |

### 2.5 Climbing and ladders

The generated world's climbable walls are Glacier (ice) faces: crevasse walls, the ice wall, the
ridge ice step and other steep faces. Rock (climbable without an axe) only shows on steep faces
near the summit.

| ID | Setup | Steps | Expected |
|---|---|---|---|
| CL-01 Ice wall with axe | Hold the ice axe (IN-14). Walk to the ice wall face near (0, ~236, 2296), facing +Z. | Press **C** and climb (W). | You latch on. `Climbing` = true; status line shows the climb controls. Climb speed 6 studs/s, reduced by glove mobility and injuries. Stamina drains at about 7/s, so the 48-stud wall takes about 8 s and over 55 stamina from fresh. |
| CL-02 Ice without axe | Axe in the pack, not held | Press C at the ice wall. | Toast "Ice. Hold an ice axe to climb it (open your pack)." If the client is bypassed, the server says "Ice. You need to hold an ice axe to climb it." |
| CL-03 Bad target | Face a gentle snow slope or a tent. | Press C. | Toast "You can't climb that." or "Face a rock wall to climb." No server climb state. |
| CL-04 Mantle at top | Climb to the ice wall lip (Y 284). | Keep holding W. | You mantle onto the top (about 0.5 s). The climb ends without a "grip fails" toast and **without fall damage**. |
| CL-05 Grip failure | Start a climb with little stamina (it needs ≥ 15). | Keep climbing until stamina hits 0. | "Your grip fails!" and you fall. Fall damage from the peak height: over 18 studs, 2.2 HP per stud above 18; over 24, 50% chance of *Sprained Ankle*; over 38, *Broken Leg* (60%) or *Sprain*; 75+ studs, *Broken Leg* and **downed**. Camera shake and −15 stamina. A fall from the top of the ice wall (about 48 studs) costs about 66 HP. |
| CL-06 Jump off | Mid-wall | Press **Space**. | You push off the wall and fall normally; fall damage applies from the peak. |
| CL-07 Climb down | Near the bottom | Hold S. | When the feet find ground you step off automatically. |
| CL-08 Ice wall ladder | At `WallFoot` (200, ~236, 2296) | Climb the ladder (engine truss climbing, no C needed) to the top. | You reach the top at (200, 284, 2310). **Watch for a snap-back to the foot partway up** (`[SurvivalService] ... moved implausibly fast; snapping back` in the server Output): reading the code, the movement sanity check counts rising more than 14.5 studs above the last ground as excess. File it if it happens. Repeat on the ridge ice-step ladder near (60, 590, 3648). |
| CL-09 Ice wall bypass | — | From the last crevasse bridge, follow the ramp west along the foot of the wall to its top at X −200, then back east along the top. | Reaches `WallTop` without climbing, but takes noticeably longer. |
| CL-10 Blocked states | Each of these in turn: carrying a player, downed, overloaded (> 1.15), Critical cold, broken leg, exhausted lockout | Press C. | "You're in no shape to climb..." (or the server equivalent). No climb starts. |
| CL-11 Crevasse fall | On the plateau | Step off a bridge into a crevasse (30-32 deep). Walk out. | About 26-31 HP of fall damage and a 50% sprain chance. An escape ramp along one wall leads back up to the plateau. |
| CL-12 Lag tolerance | Studio Settings → Network → *Incoming Replication Lag* 0.3 s | Climb the ice wall normally. | No spurious stops. The server allows 2.2× climb speed + 1.5 studs per tick. Any unexplained silent `ClimbForceStop` is a bug. |

### 2.6 Building

| ID | Setup | Steps | Expected |
|---|---|---|---|
| BD-01 Campfire | Lighter + 3 wood, flat snow | Press **B**, pick *Campfire*, aim (green ghost), R to rotate, left-click. | Stand still for **3 s** (progress bar). "Campfire built." 3 wood consumed, the lighter loses 1 of 25 uses. Prompts: E "Rest by the fire", Q "Cook food & boil water", F "Add wood". |
| BD-02 Tent | Tent pack from the outfitter (SP-04) | Build *Expedition Tent* on ground under 20°. | 5 s build. A dome tent appears. Prompts: E "Sleep in tent", F "Pack up tent" (hold 2 s). Inside, `InShelter` = true, wind cut to 10%, snow blocked. "+25 XP First emergency shelter" the first time per profile only (tent or tarp). Packing it up returns the tent pack (refused if your pack has no room). |
| BD-03 Tarp shelter | 4 wood, 2 rope, 1 tarp (Base Camp crate) | Build *Emergency Tarp Shelter* (max 22°). | 6 s build. Prompts: E "Rest under the tarp", F "Reinforce (1 rope)". Inside: wind 25%, snow blocked. |
| BD-04 Wind wall | 5 wood | Build *Wind Wall*. | 4 s build. Within 8 studs of it, wind is reduced to 40% (`WindMs` drops). Snow is **not** blocked. |
| BD-05 Trail marker | 1 wood | Build *Trail Marker* in fog. | 1.5 s build. An orange dot billboard is visible to **all** players through fog and terrain, out to 400 studs. |
| BD-06 Locked / unimplemented | — | Browse the Build Book. | Wind-Protected Fire, Snow Shelter, Rope Anchor, Snow Melter, Signal Fire and Avalanche Shelter show as "Blueprint missing" and can't be placed. |
| BD-07 Invalid: steep | — | Place a campfire (max 25°) on a valley wall or headwall slope steeper than that. | The ghost turns red; the server says "Too steep (N°, max M°)." |
| BD-08 Invalid: overlap | An existing campfire | Place a second campfire within about 4.5 studs of it, then against a camp tent, a tree or a rock. | "Something is already built there." for structures, "Blocked by <PartName>." for collidable parts. Characters never block. |
| BD-09 Invalid: out of range | — | Aim beyond 14 studs. | The ghost clamps to 13 studs. The server check is covered in X-08. |
| BD-10 Interrupt by moving | — | Start building a tarp and walk away during the timer. | "Building interrupted." once you move more than 4 studs. **No materials consumed.** |
| BD-11 Interrupt by downed / materials gone | 2 players | P1 starts a tarp, then gives away rope during the timer (or gets downed). | Giving away materials: "Not enough materials." at the end, nothing built or consumed. Downed: "Building interrupted." |
| BD-12 Busy | — | Try to start a second build during a timer. | "You're already building." |
| BD-13 Shelter wear | Tarp and tent outside in a Storm (wind 20 m/s) | Wait. Reinforce the tarp with rope (F, hold 1.5 s). | The tarp wears from 15 m/s, the tent only from 19 m/s, so the tent wears slowly. At ≤ 25 durability nearby players get a warning; at 0 "The tarp shelter collapsed!" / "The tent was torn apart by the storm!" and the model is removed. Reinforcing adds 60 durability. Snow visibly piles on the tarp roof. |
| BD-14 Structure cap | (Perf) Build 80+ markers | — | At 80 structures, the oldest non-permanent structure is removed when a new one is built. Camp fires and camp shelters are never removed. |

### 2.7 Fire and water

| ID | Setup | Steps | Expected |
|---|---|---|---|
| FR-01 Warmth | Cold (Warmth < 50), next to a lit fire | Stand within about 4 studs. | `NearFire` = true. Warmth recovers fast (a unit test asserts under a minute from freezing). A built campfire gives up to 28 °C of heat within 16 studs; camp fires 30 °C within 20 studs. Cold warnings are suppressed near the fire. |
| FR-02 Drying | Wet | Stand about 4 studs from a fire, under shelter or in clear weather. | Wetness falls quickly; while snow is still landing on you, drying is 4× slower. |
| FR-03 Rest and sleep | — | E "Rest by the fire" at a camp; then E "Sleep" on a sleeping mat in a camp tent. | You sit or lie down (`Resting` = true, `Exertion` = rest). "You lie down and rest. Move to get up." for mats. Fatigue recovers at 1.5/s, 3/s inside a camp radius. Moving faster than 3 studs/s ends the rest. Resting anywhere inside a camp heals a *Sprained Ankle* in 30 s, an *Injured Hand* in 30 s and a *Broken Leg* in 75 s. |
| FR-04 Cook, boil and melt | Canned stew, an empty thermos and a part-full bottle | Press **Q** (hold 2 s) at any lit fire. | "N food heated, M bottle(s) boiled, X.X L of snow melted." Canned stew becomes hot stew; all water becomes treated and hot (hot for 150 s, the thermos stays hot); empty space fills with melted snow. At a built campfire, melting costs 15 s of fuel per litre; camp fires are free. With nothing to do: "Nothing to cook or boil." |
| FR-05 Add wood | Lit built campfire, wood in the pack | Press **F** "Add wood". | +90 s of fuel per wood, up to 600. Near the cap: "The fire is already roaring." With no wood: "You have no wood." |
| FR-06 Burnout | A new campfire (180 s of fuel) | Time it until it goes out (a) in Clear calm at Base Camp and (b) outside any shelter in a Storm. | Burn rate = 1 + wind × windFactor / 20 + 1.5 × precipitation (unless sheltered). (a) about 165 s. (b) wind 20, precipitation 1: 3.5× rate, **about 50 s**. On burnout the flames, light and prompts disappear and the embers go grey; the model is removed after 90 s. |
| FR-07 Lighter uses | — | Build campfires until the lighter runs out. | After 25 uses the lighter leaves the pack; Campfire then says "You need a lighter." |

### 2.8 Weather and time

| ID | Setup | Steps | Expected |
|---|---|---|---|
| WX-01 Gradual transitions | Fresh server | Watch `WorldState` for 10+ minutes. | Starts Clear and holds 150–300 s. Every change is to a **neighbour state only**. `WeatherBlend` climbs smoothly over **75 s**; wind, fog, cloud and precipitation ease. It never jumps straight from Clear to Storm. Entering Fog shows the banner "Whiteout fog. Follow the red markers." |
| WX-02 Storm after Camp 1 | Any weather | Be the first player to check in at Camp 1 (CP-02). Start a stopwatch. | 60–150 s later everyone gets the banner "The wind is picking up. Dark clouds over the ridge." After a 20 s warning hold, the weather walks the shortest path to Storm, **40 s blend per step** (from Clear about 3 minutes). Banners "Heavy snow rolling in..." and "A blizzard is coming. Find shelter!"; each severe state also sends "SEVERE WEATHER APPROACHING: HEAVY SNOW / BLIZZARD". |
| WX-03 Storm after Camp 2 | After WX-02 | First player checks in at Camp 2. | A second storm is scheduled the same way. Checking in at Camp 1 or Camp 2 again (or another player doing so) schedules nothing more. |
| WX-04 Always snow | Any precipitation | Compare `Weather` at Base Camp, Camp 1 and the ridge. | Always *Light Snow* / *Heavy Snow* / *Blizzard*; never rain. Temperature falls with altitude (about 6.5 °C per 1000 m) and at night. |
| WX-05 Shelter hides snowfall | In falling snow | Walk into a camp tent or under a tarp. | `InShelter` = true, client snow particles hide, wetness stops rising. |
| WX-06 Day/night | — | Watch `Lighting.ClockTime` for 5 minutes. | It advances 24 hours per 20 minutes on every client identically (the server owns it). Night is darker and bluer; campfires and lamps brighten. |

### 2.9 Checkpoints

| ID | Setup | Steps | Expected |
|---|---|---|---|
| CP-01 Base Camp logbook | Fresh | Hold **E** (1 s) at the Base Camp logbook (7.5, 0, 27). | "You signed the Base Camp logbook. You'll return here if evacuated." No XP: Base Camp is the starting checkpoint. |
| CP-02 Camp 1 check-in ring | Arrive at Camp 1 | Step into the green ring at (−150, 200, 1615) (or sign the logbook next to it). | `Checkpoint` = 2, `CheckpointName` = "Camp 1". Banner "Checkpoint reached: Camp 1", "+150 XP Reached Camp 1" for you, "<name> reached Camp 1." for everyone. `totals.checkpoints` +1. The storm is scheduled (WX-02). The ring only fires for a camp above your current checkpoint; signing the logbook again gives the plain "You signed..." message with no XP. |
| CP-03 Respawn at camp | Checkpoint 2 | Get evacuated (RS-06), or fall below Y −30. | You respawn or are recovered within about 4 s near the Camp 1 spawn (−150, 200, 1608). Below −30: "You were recovered from the ravine, exhausted." and +20 fatigue. With **StreamingEnabled** the character must not fall through terrain that hasn't streamed in. |
| CP-04 Lower camp re-sign | Checkpoint 3 | Go back down and sign the Camp 1 logbook. | Just "You signed the Camp 1 logbook." The checkpoint stays at 3: a lower camp never moves your respawn down. |

### 2.10 Rockfall

| ID | Setup | Steps | Expected |
|---|---|---|---|
| RF-01 Natural trigger | Clear weather | Stand on the valley trail inside `ValleyAvalanche` (for example (10, ~14, 500)) and wait. Repeat on the glacier leg under the serac band (`SeracFall`). | A check every 5 s with a 7% chance × the weather `disasterMult` (Clear 1, Light 1.4, Heavy 2, Storm 3), so expect a trigger within about a minute in Clear. 75 s cooldown per zone. Nothing triggers while the zone is empty. |
| RF-02 Telegraph | When it triggers | Watch and listen. | **T−5 s:** players within 140 studs get "ROCKS ARE LOOSENING ABOVE YOU", a light camera shake for 5 s, a rumble (silent until audio ids exist), dust at the three release points, harmless pebbles trickling down. **T+0:** 3 to 5 boulders (3.5–6 studs) roll across the trail (+X in the valley; downhill under the seracs). **T+10 s:** boulders and dust disappear completely; walk the paths afterwards to check no invisible obstacles remain. Survivors in range get `disastersSurvived` +1. |
| RF-03 Injuries | Stand in a boulder's path | Get hit. | Only boulders faster than 18 studs/s hurt: 12–45 × size/5 (up to about 54). 40% *Bleeding*, 25% *Injured Hand*. At most one hit per boulder per 1.5 s. A heavy hit at low HP **downs** you. |
| RF-04 Forced trigger | Studio | Server command bar: `require(game.ServerScriptService.Server.Services.DisasterService).forceRockfall()` | A rockfall sequence starts in an occupied zone. **If nothing happens**, the command bar probably got its own copy of the module; use RF-01 and file a request for a Studio-only debug hook. |
| RF-05 Dodge | — | Run out of the boulder line during the warning. | The boulders miss you. 5 s is enough time to react. |

### 2.11 Rescue

All rescue cases need **2+ players** (Test → Clients and Servers). Quick way to get downed: set
Health to 5 from the server command bar, then take any damage, for example a 20+ stud drop into a
crevasse.

| ID | Setup | Steps | Expected |
|---|---|---|---|
| RS-01 Downed at 0 HP | P2 with low HP | P2 takes lethal damage (fall, rockfall, cold). | P2 is **not killed**: Health stays at 1 and `Downed` = true. P2 sees a red "DOWNED m:ss" overlay counting down from **2:00** and a "Give up (evacuate)" button. P2 crawls at 2 studs/s and can't jump. Everyone sees "P2 is down..." and a red DOWNED billboard over P2, visible to 500 studs. P2 can't see its own Revive/Carry prompts. |
| RS-02 Bleed-out timer | P2 downed | Watch `BleedOut`. | It counts down 1/s, 1.5× faster with *Bleeding*, 0.5× while carried and 0.5× near a fire (these multiply). Further damage while downed takes 25% of the damage off the timer. |
| RS-03 Revive without kit | P1 has no first aid kit | P1 holds **E** "Revive" on P2 for **4 s**. | P2 gets up with **30 HP**. P1 gets "+100 XP Revived P2"; `teammatesRescued` +1. Billboard and prompts disappear. |
| RS-04 Revive with kit | P1 has a first aid kit | Revive. | One kit is consumed. P2 gets up with **60 HP** and *Bleeding* removed. |
| RS-05 Carry / set down | P2 downed | P1 holds **F** "Carry" (1 s). Walk 50 studs to a fire. Press **X**. | P2 is draped across P1's shoulders. P1 moves at 0.55× speed, can't jump or climb, and drains stamina at 3.5/s. P2's bleed-out runs at half speed. X sets P2 down beside P1, still downed. Being carried causes no fall damage to P2. Note: carrying continues at 0 stamina without an auto-drop. |
| RS-06 Evacuation | P2 downed | Let the timer run out, **or** P2 holds "Give up (evacuate)" (a short click must not fire). | P2 respawns at the last signed camp: "You were evacuated to your last camp. Your gear is where you fell." Everyone sees "P2 was evacuated. Their pack is still on the mountain." A big bundle "P2's pack" holds **all pack contents** where P2 lay. P2 keeps worn clothes and pack, and gets a 500 ml treated bottle and an energy bar. Hunger and thirst at least 60, warmth at least 70, injuries and wetness cleared, stamina 40, fatigue +25. |
| RS-07 Recover pack | After RS-06 | P1 (and separately P2) holds E (1.5 s) on "P2's pack". | Items move up to the slot and weight limits: "You took what you could carry." / "Your pack is full or too heavy." / when emptied, the bundle disappears and others see "You recovered P2's gear." (not P2 itself; retest with an account whose DisplayName ≠ Name). The bundle sits on the ground. It despawns after 30 minutes. |
| RS-08 Downed carrier | P1 carrying P2 | P1 gets downed. | P2 is released beside P1; both are downed. |
| RS-09 Climb while carrying | P1 carrying | P1 presses C at an ice face. | Refused. |
| RS-10 Treat a downed teammate | P2 downed and *Bleeding*, P1 has a bandage | P1: pack → bandage → Treat P2. | Bleeding is removed and the bleed-out rate drops from 1.5/s to 1/s. P2 stays **downed**: treatment never revives. |
| RS-11 Hypothermia knock-out | SV-05 | Stay at Critical warmth for 20 s. | Downed with cause "hypothermia". A revive resets the critical-cold timer. |

### 2.12 Summit summary

| ID | Setup | Steps | Expected |
|---|---|---|---|
| SE-01 | Reach the summit by the ridge | Walk within 16 studs of (0, 800, 4160) (flag and cairn). | Within 1 s: "+1000 XP Reached the summit", the banner and notification "<name> reached the summit!" for everyone, and a summary panel with name, max elevation (m), distance (m, at 0.28 m/stud, ignoring jumps > 40 studs per tick), time, highest checkpoint, weather survived (severe states lived through while exposed), disasters survived, teammates rescued, items consumed, injuries and resources collected. `totals.sectionsCompleted` and `totals.summits` +1. Only once per expedition, and not while downed. |
| SE-02 | Downed inside the radius | Get revived inside the radius. | The summary appears after the revive, not while downed. |

### 2.13 Saving

| ID | Setup | Steps | Expected |
|---|---|---|---|
| DS-01 API access off | Game Settings → Security → *Enable Studio Access to API Services* **off** | Play. | Output: `[DataService] Studio has no DataStore access; running in-memory.` (or "DataStore unavailable..."). You play normally with a default profile. Nothing persists after Stop. |
| DS-02 Progression persists | API access **on** (a test place, never the live universe) | Play. Check in at Camp 1 (+150 XP). At the outfitter wear the insulated parka and switch to the large pack. Stop. Play again. | `XP` = 150 and `Rank` = "Beginner Mountaineer". You spawn wearing the parka with the large pack (the saved loadout applies). **Pack contents, injuries and the checkpoint reset**: an expedition is per session. `totals.expeditions` increments each session. |
| DS-03 Rank up | API on | Gain 500+ XP across sessions (camps 150 each, summit 1000, first shelter 25, revive 100). | "Rank up: Hiker" on crossing 500, and it persists. |
| DS-04 Autosave / shutdown | API on | Gain XP, wait 2+ minutes (autosave every 120 s), then stop. | No errors. Data from both the autosave and the BindToClose save is there on the next run. Close waits up to 25 s for pending saves. |
| DS-05 Session lock | Published test place, two servers | Join server A, leave and immediately join server B. | Server B may log `[DataService] <name> is locked by another server (attempt n)` and retry. Once A's leave-save releases the lock, B loads the **latest** data. If the lock never clears: "Your saved progress couldn't be loaded..." and the session is read-only. Nothing is overwritten. |
| DS-06 Quick rejoin, same server | API on, published test place | Leave and rejoin the same server within a few seconds. | The new session waits (up to 30 s) for the previous session's final save. No "locked by another server" loop. |
| DS-07 Leave during load | API on, slow DataStore | Leave within 1 s of joining, then join a different server. | No 10-minute lockout: the lock taken by the abandoned load is released. |
| DS-08 Corrupt / legacy data | API on, write junk to key `u_<userId>` in store `MountainProfiles_v1` | Play. | The profile is repaired: unknown items and blueprints are dropped and numbers are clamped. No crash. |

---

## 3. Multiplayer matrix

Use **Test → Clients and Servers**, choose the player count and press Start. Each client gets its
own window, and the Server window has the server command bar. Re-run the solo checks in each
configuration and add the ones below. Everything server-built must look identical on every client:
gear, structures, boulders, downed markers, trail markers and pings.

| Check | Solo | 2 players | 4 players | 6 players |
|---|---|---|---|---|
| Boot: no errors, HUD on every client, each player has its own loadout | ✔ | ✔ | ✔ | ✔ |
| Spawn: all spawn on the Base Camp pad without stacking or getting stuck, including players who joined during world generation | ✔ | ✔ | ✔ | ✔ |
| Teammate list (top-left) shows the others with DOWNED / injured / freezing | — | ✔ | ✔ | ✔ (list fits 5 names) |
| Give / Treat buttons list only teammates within 10 studs | — | ✔ | ✔ (crowd 3 players together) | ✔ |
| Ping (G): marker and name visible to all within 600 studs. Spam is rate limited (0.5/s, burst 3) | ✔ (self) | ✔ | ✔ | ✔ (all 6 ping together) |
| Equipment visuals and head-gear toggles replicate, including wetness and snow on other players' packs | — | ✔ | ✔ | ✔ |
| Supply crate / outfitter allowances are **per player** | — | ✔ | ✔ | ✔ |
| Weather and clock are identical for all players; temperature differs by altitude | ✔ | ✔ (split P1 Base Camp, P2 Camp 2) | ✔ | ✔ |
| Storm director fires once per camp per server, triggered by the *first* player to reach Camp 1 / Camp 2 | ✔ | ✔ | ✔ | ✔ |
| Rescue: revive, carry, set down, evacuate, recover pack | — | ✔ (full RS suite) | ✔ (two downed at once, two rescuers on one target) | ✔ |
| Building near others: players never block placement, structures block each other; anyone can pack up a tent | — | ✔ | ✔ | ✔ |
| Rockfall with several players in a zone: each can be hit, the telegraph reaches everyone within 140 studs | ✔ | ✔ | ✔ | ✔ |
| Checkpoint: each player checks in separately; "X reached Camp 1" broadcast once per player | ✔ | ✔ | ✔ | ✔ |
| Rope bridges and ladders with several players on them at once | — | ✔ | ✔ | ✔ |
| Summit: per-player summary, broadcast to all | ✔ | ✔ | ✔ | ✔ |
| Performance (section 5): server heartbeat, network, memory | baseline | — | ✔ | **target config** |

At 4 and 6 players, also run one full **15–25 minute expedition** with everyone: Base Camp →
valley → Headwall → Camp 1 → storm → crevasse bridges → split at the ice wall (some on the
ladder or climbing, the rest on the bypass) → Camp 2 → ridge → summit. Watch for desyncs, stuck
prompts, errors and frame drops.

---

## 4. Edge cases and exploit tests

### 4.1 Gameplay edge cases

| ID | Case | Steps | Expected |
|---|---|---|---|
| E-01 | **Disconnect while carrying** | P1 carries downed P2. Kick P1 or close P1's window. | P2 is released at P1's last position, still downed, bleed-out at full speed again, Revive/Carry prompts still work. No orphaned weld, no massless/PlatformStand left on P2, and P2 can crawl. |
| E-02 | **Disconnect while being carried** | P1 carries P2. Kick P2. | P1's `Carrying` clears and P1 is back to normal speed, jumping and climbing. No leftover parts on P1. |
| E-03 | **Disconnect during building** | P1 starts a 6 s tarp build. Kick P1 at 3 s. | Nothing is built, no errors. On rejoin within 10 minutes (same server) P1 still has the materials and isn't "already building". |
| E-04 | **Downed with inventory open** | Open the pack, then get downed. | Use / Give / Treat / Wear return "You're incapacitated." **Drop is allowed.** The UI shows nothing stale after a revive. |
| E-05 | **Two players pick up the same item** | P1 drops a stack. P1 and P2 both hold E on the bundle and release together. Repeat with an evacuated pack. | Each item is granted **once** in total. No duplication. The model disappears once empty. |
| E-06 | **Two players build in the same spot** | P1 and P2 both start a campfire on the same spot. | Whoever finishes first builds. The other is refused at the end with "Something is already built there." and **keeps their materials**. |
| E-07 | **Two players pack up the same tent** | P1 and P2 hold F "Pack up tent" together. | Exactly one tent pack is created; the tent disappears once. |
| E-08 | **Rejoin after evacuation** | P2 is evacuated. P2 leaves and rejoins the **same server** within 10 minutes. | "Welcome back. Your expedition was waiting for you." P2 keeps the post-evacuation state, checkpoint and `outfitterTaken` / `supplyTaken` allowances. The dropped pack is still on the mountain and not duplicated. |
| E-09 | **Rejoin after 10+ minutes / new server** | Leave for > 600 s, or join a different server. | A fresh expedition with a new loadout from the saved profile. Progression is kept (when saving is on). |
| E-10 | **Check in during a disaster** | Check in at Camp 1 mid-storm, and while a rockfall is active elsewhere. | Check-in works normally. The storm scheduler doesn't schedule a second storm for the same camp. |
| E-11 | **Downed while climbing / during mantle** | Get hit by damage while on the wall. | The climb stops, the client releases the wall and you fall downed. No floating in place. |
| E-12 | **Climbing while server says stop** | Drain stamina while hanging. | The client lets go immediately on `ClimbForceStop`. No "ghost climbing". |
| E-13 | **Reset character** | Try Esc → Reset. If somehow available, run `...Humanoid.Health = 0` in the server command bar while downed. | The reset button should be disabled. If a death happens, the player respawns at the last camp and the downed state clears. **Known risk:** that path keeps the full pack and skips evacuation. File it if reachable without the command bar. |
| E-14 | **Fall off the world** | Walk off the terrain onto the snow skirt and beyond, or fall below Y −30. | Recovered to the checkpoint after about 3 s. No infinite falling (safety floor at −120). |
| E-15 | **Respawn during weather and streaming** | Evacuate to Camp 2 in a blizzard on a slow connection. | You don't fall through terrain that hasn't streamed in. HUD weather updates immediately. |
| E-16 | **Revived while carried** | P1 carries P2. P3 revives P2. | The carry is released and P2 stands up beside P1. |
| E-17 | **Give to a downed player at the moment they are evacuated** | P1 gives P2 an item as P2's timer expires. | The item ends up in P2's dropped pack or P2's new pack, never both. |
| E-18 | **Join during world generation** | Join while `[World]` has not printed yet (start a server and join immediately). | No character until the world is built, then a normal spawn at Base Camp. |

### 4.2 Exploit and robustness tests (remote spam)

Run these from a **client window's command bar**. In *Clients and Servers*, select a client
window; its command bar runs as that client, so `FireServer` works. Watch the **server** Output.

Expected for every rejected call: the server ignores the request. A `RemoteFunction` returns
`false, "Request rejected."` (or a handler message), the server never errors, other players are
unaffected, and the server logs `[RemoteGuard] <name> rejected on <remote>: <reason> (total N)`
on the 1st, 26th, 51st... rejection. There is no automatic kick (`SUSPICION_KICK_THRESHOLD = 0`).

```lua
local R = game.ReplicatedStorage.Remotes
local nan, inf = 0/0, math.huge
```

| ID | Attack | Command (client command bar) | Expected |
|---|---|---|---|
| X-01 | NaN / inf vectors | `R.Ping:FireServer(Vector3.new(nan,0,0))`, `R.Ping:FireServer(Vector3.new(inf,0,0))`, `R.ClimbStart:FireServer(Vector3.new(nan,0,1))` | Rejected (schema: finite and magnitude-limited). |
| X-02 | Huge numbers | `R.Ping:FireServer(Vector3.new(1e6,0,0))` (> 20000), `R.ClimbStart:FireServer(Vector3.new(0,0,50))` (magnitude > 1.5), `R.Inventory:InvokeServer("Drop", "1", 2^60)` | Rejected. A Drop with a valid huge integer (≤ 2^53) is clamped to the stack size. |
| X-03 | Wrong types / arity | `R.Inventory:InvokeServer({}, {}, {})`, `R.SetSprint:FireServer("yes")`, `R.Inventory:InvokeServer("Use", "1", nil, "extra")`, `R.Outfit:InvokeServer(string.rep("a", 10000))`, `R.Build:InvokeServer("campfire", Vector3.new())`, `R.GearToggle:FireServer("Boots", true)` | Rejected: bad argument, too many arguments, string too long or not in the allowed list. |
| X-04 | Invalid enum / quantity | `R.Inventory:InvokeServer("Dupe", "1")`, `R.Inventory:InvokeServer("Drop", "1", 0)`, `R.Inventory:InvokeServer("Drop", "1", 1.5)`, `R.Inventory:InvokeServer("Drop", "1", -5)` | Rejected by schema. |
| X-05 | Forged stack uids | `R.Inventory:InvokeServer("Use", "99999")`, `("Give", "99999", <otherUserId>)`, `("Drop", "abc")`. Try another player's uid. | "You don't have that." Uids are per-inventory, so another player's uid can only ever refer to your own stack. No crash, no item creation. |
| X-06 | Give / Treat abuse | `R.Inventory:InvokeServer("Give", uid, <yourOwnUserId>)`, `("Give", uid, 1)`, `("Give", uid, <far player>)`, `("Treat", uid_of_energy_bar, <mate>)` | "No one to give that to." / "Get closer..." / "That can't be used on someone else." Nothing moves. |
| X-07 | Supply / outfitter from afar | From 50+ studs away: `R.Supply:InvokeServer("BaseCamp", "first_aid_kit")`, `R.Outfit:InvokeServer("pack_expedition")`. At the Camp 1 crate: `R.Supply:InvokeServer("Camp1", "tarp")` (not in that crate). At the outfitter: `R.Outfit:InvokeServer("hot_stew")` (not stocked) | "You need to be at that supply crate." / "You need to be at the outfitter." / "Not in this crate." / "Not available." Allowances aren't consumed. |
| X-08 | Build from 500 studs | `local p = game.Players.LocalPlayer.Character.HumanoidRootPart.Position` then `R.Build:InvokeServer("campfire", CFrame.new(p + Vector3.new(0,0,500)))` | "Too far away." Also `CFrame.new(nan,0,0)` and `CFrame.new(1e6,0,0)` are rejected by schema; `R.Build:InvokeServer("signal_fire", CFrame.new(p))` gives "You don't know how to build that yet."; a valid recipe without materials gives "Not enough materials." |
| X-09 | Build rotation abuse | `R.Build:InvokeServer("wind_wall", CFrame.new(p + Vector3.new(3,0,0)) * CFrame.Angles(math.pi/2, 0, 0))` | Only yaw is kept: the structure is upright. |
| X-10 | Rate-limit spam | `for i=1,500 do R.SetSprint:FireServer(i%2==0) end`, `for i=1,200 do R.Ping:FireServer(p) end`, `for i=1,100 do task.spawn(function() R.Inventory:InvokeServer("Use", "1") end) end`, `for i=1,200 do R.GearToggle:FireServer("Light", i%2==0) end` | Only the burst plus the sustained rate gets through (SetSprint 12 + 8/s, Ping 3 + 0.5/s, Inventory 10 + 6/s, GearToggle 8 + 4/s). Excess calls are dropped and logged every 25 rejections. Server heartbeat doesn't dip noticeably. |
| X-11 | ProximityPrompts from range | In the client command bar: `for _,p in workspace:GetDescendants() do if p:IsA("ProximityPrompt") then p.MaxActivationDistance = 1000 end end`. Then trigger the Base Camp crate, a wood source, the Camp 1 logbook, a sleeping mat and a downed teammate's Revive from 100+ studs. | The server re-checks distance against its own `MaxActivationDistance + 4`, so **nothing happens**. |
| X-12 | Climb hacks | Without facing a wall: `R.ClimbStart:FireServer(Vector3.new(0,0,1))`. Facing ice without a held axe: same. Fly up while `Climbing` (teleport the client root up by 30 studs). | "Nothing to climb here." / "Ice. You need to hold an ice axe...". A climb with an implausible vertical speed is force-stopped and you fall with normal fall damage. |
| X-13 | Downed-state remotes | Not downed: `R.GiveUp:FireServer()`. Not carrying: `R.DropCarried:FireServer()`. While carried: `R.StopRest:FireServer()`. | Ignored. |
| X-14 | Jump stamina dodge | Jump repeatedly while blocking `ReportJump`. | Known limitation: the jump cost is client-reported. Server-side `JumpHeight` = 0 below 9 stamina still applies. Record the result. |
| X-15 | Snapshot spam | `for i=1,50 do R.GetSnapshot:InvokeServer() end` | Limited to 4 + 2/s. Returns a copy: mutating it on the client changes nothing on the server. |

---

## 5. Performance checklist

### 5.1 Targets

| Metric | Target | Where to read it |
|---|---|---|
| **World generation** | Record the `[World] ... built in X.XXs` and `model X.XXs` times and the voxel count on every build. Treat a large jump as a regression. Players must not be able to spawn before it finishes. | Server Output |
| **Server heartbeat** | **≥ 55 fps sustained at 6 players** during the storm + rockfall + 6 fires + 6 tents scenario. No spikes > 50 ms. | Developer Console (F9) → *Server* → **Server Stats** / *Scripts*. In Studio, the Server window → View → Stats → Performance. |
| **Client FPS, low-end phone** | ≥ 30 fps at Base Camp (densest props) and in a blizzard on the ridge, on a low-end device (for example a 3 GB RAM Android, or iPhone 8 / SE2 class). | Ctrl+Shift+F5 / Developer Console *Client*, or the device's own overlay. |
| **Client FPS, desktop** | ≥ 60 fps | Same. |
| **Client memory, mobile** | Total < about 1,000 MB. LuaHeap stable over a 20-minute run. Terrain memory recorded. | Developer Console → **Memory** (*PlaceMemory*, *LuaHeap*, *Instances*, *PhysicsParts*, *TerrainVoxels*, *GraphicsTexture*). |
| **Network** | Idle player: near-zero attribute traffic. Steady state < about 30 KB/s received per client at 6 players. Streaming in terrain while walking the route should not stall. | Developer Console → **Network**, or Studio View → Stats → Network. |
| **Part counts** | Record the `[Report] ... world parts N` baseline, and treat > 10% growth from one build to the next as a regression. Gear per character: aim ≤ about 80 parts with the full kit. Structures are capped at 80, boulder pool at 10. `GroundItems` should return to 0 after despawns. | `[Report]` line; Explorer folders `workspace.Structures`, `workspace.GroundItems`, `workspace.DisasterEffects`, `<Character>.Gear`. |

### 5.2 Tools

* **MicroProfiler** (Ctrl+F6 on the client; on the server in Studio, use the Server window's
  MicroProfiler, or Developer Console → MicroProfiler on a live server). Pause on a spike and look
  at the `Heartbeat` / `RunService` bars and `physicsStepped`. All server services run under one
  Script ("Server"), so add `debug.profilebegin("SurvivalTick")` ... `debug.profileend()` labels in
  the hot loops before a perf pass.
* **Developer Console (F9):** Memory (Instances and PhysicsParts flat over time, LuaHeap not
  climbing; compare before and after 10 builds, 10 rockfalls, 5 evacuations and 50
  drops/pickups), Network (idle vs moving vs storm), Scripts (the "Server" script should stay low
  single-digit % at 6 players), Log (zero errors; `[RemoteGuard] ... rejected` only during exploit
  tests).
* **Studio Script Performance** window during the 6-player test.

### 5.3 What to look for, system by system

| System | Cost driver | Watch for |
|---|---|---|
| WorldBuilder | `TerrainModel.new` (pure Luau), then `WriteVoxels` per 64×64-stud chunk with frame yields; a few thousand Parts for camps, props and route. | Startup time and memory; streaming pop-in of camps, markers and backdrop peaks; whether the Part-built backdrop peaks and snow skirt are visible from the route as intended. |
| SurvivalService | One Heartbeat accumulator, a 5 Hz tick per player. Each tick does one ground raycast, a `WaterVolume` scan, `BuildingService.environmentAt` (loops over every structure and camp shelter volume) and about 35 attribute publishes with change thresholds. | Tick cost grows with players × structures. Confirm < 1 ms per tick at 6 players and 80 structures. Idle players' attributes shouldn't change. |
| WeatherService | Heartbeat every frame plus 10 `WorldState` attributes at 2 Hz, and `Lighting.ClockTime` every publish. | `WindDirection` and `ClockTime` change every publish, so they always replicate; small but constant. Client WeatherController: one snow emitter above the camera. Check particle fill rate in a blizzard on mobile. |
| BuildingService | 1 Hz fuel, wear and roof-snow simulation. | Roof snow transparency writes replicate every second while it snows. Check traffic with 6+ tarps. |
| EquipmentService | Gear is rebuilt when the visual signature changes (including head-gear toggles). Wet recolour in 10 buckets. Snow cap at 1 Hz. | Rebuilds only on gear, pack, held, toggle or wood-threshold changes. Look for bursts of instance creation while gathering wood or eating. |
| DisasterService | Server-owned boulder physics (3–5 balls), dust emitters, pebbles. | A physics spike at release. Afterwards `DisasterEffects` must empty. |
| ResourceService | Ground bundles from drops and evacuations. | Drop is allowed at 6/s; spam Drop for 1 minute and count `GroundItems` children. |
| RescueService | 1 Hz loop, a billboard per downed player. | Billboards and prompts are destroyed after revive or evacuation. |
| CampService | 1 Hz ring and summit distance check over all players × camps. | Negligible. |
| Client HUD | Refreshes at 10 Hz; teammate list. | GC churn on mobile. |
| Client cosmetics | FootprintController (pooled parts, one raycast per step per character), AmbienceController (light sweeps in batches), ConditionController (breath on every character). | Frame time on mobile at Base Camp with 6 players walking. |
| Client climbing / build ghost | 2–3 raycasts per frame while climbing. A raycast every RenderStepped while placing. | Frame time on mobile while climbing in a blizzard. |

### 5.4 Perf scenario script (6 players, about 10 minutes)

1. All 6 spawn and gather wood near Base Camp. Record the baseline server heartbeat, part count
   and client memory.
2. Everyone builds a campfire and a trail marker. Two players pitch tents and one builds a tarp.
   Record again.
3. Teleport everyone to Camp 1 and check in (the storm comes 60–150 s later).
4. During the blizzard, three players stand in the `SeracFall` zone until a rockfall triggers,
   and one gets downed and carried.
5. Spam Drop and pick-up from one client for 60 s.
6. Record peak and average server heartbeat, the worst client FPS (phone), Network KB/s and
   Memory, then compare with the targets in 5.1.

---

## 6. Bug report template

```markdown
### Title
<Area>: <short symptom> (e.g. "Rescue: carried player keeps PlatformStand after carrier disconnects")

**Build / commit:** <git short SHA>        **Date:** <YYYY-MM-DD>
**Test case:** <ID from docs/TESTING.md, e.g. RS-05 / E-01 / X-08, or "exploratory">
**Mode:** Studio Play / Clients and Servers (N players) / published test place / device: <model, OS>
**API Services access:** on / off        **Avatar rig:** R15 / R6

**Severity:** Blocker / Critical / Major / Minor / Cosmetic
**Frequency:** Always / Often (x of y) / Rare / Once

**Setup**
<starting state: location (X, Y, Z or route id such as Camp1 / WallFoot), weather, time of day, gear, pack contents, checkpoint>

**Steps to reproduce**
1.
2.
3.

**Expected** (quote the doc's Expected column if a test case exists)

**Actual**

**Evidence**
- Output / Developer Console log lines (server and client, copied as text), including the `[World]` and `[Report]` lines:
- Relevant Player attributes at the time (Stamina, Warmth, Downed, Injuries, Weight, ...):
- WorldState attributes (WeatherFrom/To/Blend, ClockTime) if weather related:
- Screenshot / video:
- MicroProfiler dump (perf bugs):

**Notes / suspected cause** (optional; file and line if known)
```

Severity guide:

* **Blocker:** the test plan can't proceed (no client boot, server error on start, world fails to
  build, can't leave Base Camp).
* **Critical:** progress or data loss, item duplication, a server crash, or an exploit that grants
  items, XP or teleports.
* **Major:** a core mechanic is wrong (fall damage, rescue, weather, saving, an impassable route
  section).
* **Minor:** wrong numbers or messages, a UI glitch.
* **Cosmetic:** visual only.
