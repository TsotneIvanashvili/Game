# Roadmap

Honest status of the mountain-survival expedition. How the systems work is in
[ARCHITECTURE.md](ARCHITECTURE.md).

**Overall: playable build, NOT yet play-tested in Roblox Studio.** Everything below marked
"done" compiles with the real Luau compiler and passes selene and StyLua. The pure logic layer
passes the unit/stress tests in `tests/spec.luau`, the world layout and terrain pass
`tests/spec_terrain.luau`, and the real server and client boot and play a scripted expedition
in a headless Roblox emulation (`tests/spec_boot.luau`). How to run them, and the manual Studio
test plan, are in [TESTING.md](TESTING.md). None of it has run inside Roblox yet, so every
engine-facing item still carries a "needs Studio testing" caveat: physics, rendering,
replication, streaming, terrain voxels and DataStores are not emulated.

Status legend

| Status | Meaning |
|---|---|
| Done in code | Implemented end to end (server + client where relevant), not yet run in Studio |
| Done + unit tested | As above, and the logic is covered by `tests/spec.luau` or `tests/spec_terrain.luau` |
| Boot tested | The flow runs without errors in `tests/spec_boot.luau` (headless emulation, not the engine) |
| Partial | Some of the checkpoint exists; the gap is listed |
| Not started | No code yet |
| Needs Studio testing | Can only be verified in a running place (physics, feel, replication, DataStores) |

> The design brief itself is not checked into this repository. Checkpoint titles and the slice
> steps below are paraphrased from it; reconcile wording and numbering against the brief.

---

## Development checkpoints

| # | Checkpoint | Status | What exists / what's missing |
|---|---|---|---|
| 1 | Project foundation (Rojo, folder layout, Registry, PlayerStore, remotes, config modules, test tooling) | **Done** | `default.project.json`, `rokit.toml`, bootstrap, RemoteGuard, `tests/check.sh` (compile, lint, format, all suites) |
| 2 | Movement, sprint and stamina | **Done + unit tested**, boot tested; needs Studio testing | Server sets WalkSpeed/JumpHeight from survival modifiers every 0.2 s; MovementController sends sprint/jump intent. Feel (speeds, FOV, jump cost) untested. No custom animations |
| 3 | Survival stats: hunger, thirst, fatigue, health, oxygen, altitude sickness | **Done + unit tested** | SurvivalModel + SurvivalService; icon stats on the HUD; notifications |
| 4 | Temperature, clothing layers, wetness, frostbite | **Done + unit tested** | WarmthModel (per region), 25 clothing items over 8 slots, fire heat, shelters, frostbite stages, day/night temperature; climate tests per camp |
| 5 | Inventory, backpack tiers, weight and slots | **Done + unit tested** (model, 10k-op stress test), boot tested; UI needs Studio testing | InventoryService, InventoryController, hotbar 1-4, 4 pack tiers, 130% hard cap |
| 6 | Visible equipment on the character | **Done in code**, boot tested; needs Studio testing | EquipmentService + GearFactory (stylized v2): parka with fur ring, pants, gloves, crampon boots, helmet with headlamp, mask, goggles, pack by tier, harness, stowed axe/rope/tarp/wood, held axe, wet darkening, snow on pack. Head-gear toggles (H) |
| 7 | Climbing (rock, ice with ice axe) | **Done in code**, boot tested (start + climb); needs Studio testing | Client motion via AlignPosition/AlignOrientation, server start/tick authority, grip failure. Ladders are TrussParts (engine climbing). Mantle, latency tolerance and feel are untested |
| 8 | Injuries, fall damage, medical items | **Done + unit tested** | 11 injury types with cure paths; splints, bandages, first aid kit; fall thresholds; camp rest on sleeping mats |
| 9 | Resources: wood, water, food, cooking, boiling | **Done in code**, boot tested | WoodSource prompts (scarce, mostly low on the mountain), camp meltwater stations, melt snow / cook / boil at any fire, thermos. No streams (water comes from snow) |
| 10 | Building: Build Book, campfire, emergency shelter | **Partial**, boot tested | 5 of 11 recipes (campfire, tent, tarp shelter, wind wall, trail marker); full server validation; placement ghost. Missing: wind_fire, snow_shelter, rope_anchor, snow_melter, signal_fire, avalanche_shelter |
| 11 | Weather | **Done in code** (graph logic unit tested), boot tested; visuals need Studio testing | 7-state neighbour graph, blending, forced storm path, always snow, 20-minute day/night cycle, weather banners. WeatherController renders sky/fog/snow; lightning is not rendered |
| 12 | Natural disasters | **Partial**, boot tested (forced rockfall) | Rockfall fully telegraphed and pooled, in two zones (valley avalanche slope, serac band). A real snow avalanche is **not started** (design in ARCHITECTURE section 13) |
| 13 | Multiplayer teamwork: downed, revive, carry, give, treat, pings | **Done in code**, boot tested (2 clients); needs multi-client Studio testing | RescueService, Give/Treat, PingController, teammate list on HUD, rejoin stash, leave-while-downed = evacuation. Rope teamwork **not started** |
| 14 | Checkpoints, expedition flow, progression | **Done in code**, boot tested | Base Camp, Camp 1, Camp 2 with check-in rings, logbooks and sleep spots; respawn at last camp; director (storm after Camp 1 and after Camp 2); summit summary; XP/ranks. Blueprint unlocks have no in-game source yet |
| 15 | Saving and loading | **Done in code**, boot tested (mock DataStore, outage, shutdown); needs live DataStore testing | Session lock, retries, sanitize, read-only fallback, autosave, BindToClose, quick-rejoin handling. Requires a published place with Studio API access |
| 16 | Audio, VFX, art, polish, optimization, QA | **Partial** | Art pass v2 done (stylized Part-built camps, tents, props, gear, UI; title screen, compass, banners, footprints, fire/lamp ambience). Still: every sound id is empty (game is silent), particles use default textures, no meshes, no animations, no profiling, no in-Studio test pass |
| 17 | World v3: natural mountain | **Done + unit tested** (`spec_terrain`), boot tested; needs Studio testing | Heightfield terrain from `TerrainModel`, written with `WriteVoxels` in chunks, Base Camp first; camps, bridges, ladders, markers, fences, backdrop peaks, snow skirt. Generation time, voxel look and walkability need checking in the engine |
| 18 | Offline verification tooling | **Done** | Headless Roblox emulation + boot test (`tests/mock`, `tests/spec_boot.luau`); approximate preview renderer and geometry checks (`tests/render`, images in `docs/previews/`) |

---

## Vertical slice: route checklist

The slice is the whole mountain: Base Camp -> valley -> Headwall switchbacks -> Camp 1 ->
crevasse plateau with rope bridges -> ice wall (ladder or bypass) -> glacier switchbacks under
a serac band -> Camp 2 -> knife-edge ridge (notch bridge, ice-step ladder) -> Summit
(y 800 = 3500 m). Every step below is implemented in code; **none has been played through in
Studio**. The boot test covers many steps by teleporting along the route, not by walking it.

| # | Step | Systems implementing it | Status |
|---|---|---|---|
| 1 | Join, title screen, spawn at Base Camp once the world is built | WorldBuilder, `CharacterAutoLoads` gate, TitleController, PlayerService, DataService | Boot tested |
| 2 | Start in the default expedition kit with a starter pack | LoadoutConfig, InventoryService.setupLoadout, EquipmentService | Boot tested |
| 3 | Change clothing, pack or take a tent at the outfitter (equipment tent) | CampService prompt -> `OpenPanel` -> PanelController -> `Outfit` -> InventoryService; saved to `profile.loadout` | Boot tested |
| 4 | Take food and medical supplies from the crate | `Supply`, per-player allowance (BaseCamp / Camp1 / Camp2) | Boot tested |
| 5 | Check pack weight and contents; hotbar; gear toggles | InventoryController (Tab / I), HotbarController (1-4), GearMenuController (H) | Boot tested |
| 6 | See your gear on your character (and on teammates) | EquipmentService, GearFactory | Boot tested (parts exist); looks need Studio |
| 7 | Hike the valley; gather wood | WorldLayout route + WoodSources, ResourceService, SurvivalService exertion | Boot tested (teleported) |
| 8 | Manage hunger, thirst, stamina and fatigue; melt snow and boil water at a fire | SurvivalModel, InventoryService Use, BuildingService fire prompts, camp meltwater | Done + unit tested |
| 9 | Rockfall off the avalanche slope: warning, boulders, injuries | DisasterService (`ValleyAvalanche`) | Boot tested (forced) |
| 10 | Switchbacks up the Headwall to Camp 1 | TerrainModel corridors, marker poles | Done + terrain tested |
| 11 | Check in at Camp 1 (ring or logbook) | CampService, ProgressionService XP, new respawn point, Banner | Boot tested |
| 12 | The storm comes: shelter in a camp tent, pitch your own tent, or build a tarp | ExpeditionService -> WeatherService.force("Storm"), camp `ShelterVolume`s, tent/tarp durability | Boot tested (forced storm, tent) |
| 13 | Cross the crevasse plateau on rope bridges (escape ramps if you fall in) | RouteKit.ropeBridge, crevasse ramps in TerrainModel | Done + terrain tested; bridge feel needs Studio |
| 14 | Ice wall: ladder, ice-axe climb, or the long bypass ramp | RouteKit.ladder (TrussPart), ClimbingService (Glacier), `Alternates.IceWallBypass` | Terrain tested; ladder vs movement sanity check is suspect (see known gaps) |
| 15 | Glacier switchbacks under the serac band; serac fall | DisasterService (`SeracFall`) | Done in code |
| 16 | Check in at Camp 2; second storm; finite woodpile | CampService, ExpeditionService | Boot tested (ring) |
| 17 | Get cold with altitude, wind, night and wet clothes; frostbite warnings | WarmthModel, WeatherModel day/night, SurvivalService, ConditionController, HUD | Done + unit tested |
| 18 | A teammate goes down: revive, carry, treat, or they evacuate | RescueService, InventoryService Treat, MovementController (X), HUD downed overlay | Boot tested; needs multi-client Studio testing |
| 19 | The knife-edge ridge: fences, notch bridge, ice-step ladder, fixed ropes | RouteKit, WorldLayout Fences/FixedRopes | Done + terrain tested |
| 20 | Reach the summit and see the expedition summary | CampService SectionEnd -> ExpeditionService.sectionComplete -> SummaryController | Boot tested |
| 21 | Progress is saved (XP, rank, totals, loadout) | DataService, ProgressionService | Boot tested (mock); needs live DataStore testing |

---

## Next steps

Highest priority first.

1. **Studio play-test pass** (the gate for everything else). Build with Rojo, run solo and a
   6-player local server, walk the whole route, and log every bug. Specifically verify:
   terrain generation time and look (`[World] ...` line), that the route is walkable at real
   humanoid physics, ladders, rope bridges, climbing feel and mantle, carry welds, fall damage
   thresholds, build placement on terrain, rockfall boulder paths, weather and night visuals,
   streaming around camps, DataStore session locking across two servers.
2. **Ladders vs the movement sanity check**: confirm whether a player climbing the ice wall
   ladder is snapped back (see known gaps) and exempt engine climbing
   (`HumanoidStateType.Climbing`, or ground checks against the ladder) if so.
3. **Tune the server movement sanity check** (SurvivalService; see ARCHITECTURE section 14)
   against real play: knockback from boulders, steep slopes, jumping off walls, lag spikes.
4. **Audio IDs**: fill every key in `src/client/AudioConfig.luau` (Wind, Snowfall, Blizzard,
   Rumble, StormBanner, FireCrackle, HeavyBreathing, Heartbeat, Shivering, SnowStep, IceStep,
   RockStep). Until then the game is silent.
5. **Climate and altitude tuning** in real play: storm and night temperatures per camp, how
   long a starter suit lasts, and the oxygen curve (it only falls to about 88 at the summit, so
   the "LOW OXYGEN" warning below 80 never fires).
6. **Real avalanche** on the valley's `AvalancheSlope`, following ARCHITECTURE section 13
   (`AvalancheZone` tag, telegraph, sweep, buried/dig-out state, `avalanche_shelter` recipe).
7. **Rope teamwork**: implement `rope_anchor` (recipe exists, `implemented = false`), make the
   ridge's fixed ropes do something (they are decorative), roped travel on the crevasse plateau,
   belay assist on climbs.
8. **Crampon gameplay**: the expedition boots and overboots show crampons and say "grip on
   ice", but nothing reads it yet (no ice slipping, no cheaper ice climbing).
9. **Animations**: climbing, crawling while downed, being carried, sleeping, resting by the
   fire, building, eating/drinking, shivering. Currently everything uses default animations.
10. Remaining Build Book recipes, and an in-game source for blueprint unlocks
    (`ProgressionService.unlockBlueprint` is never called yet).
11. Settings UI: `profile.settings.cameraShake` is saved but nothing reads or changes it.
12. Profiling with 6 players (MicroProfiler, network stats), then decide whether
    `BuildingService.environmentAt` needs a spatial grid and whether the voxel count can drop.
13. **Real art** where Parts are not enough: meshes per `docs/ASSET_SPECS.md` (keeping the
    anchor and child names services rely on), item icons, snowflake/breath/dust particle
    textures.

---

## Known gaps found while documenting

Small mismatches between code, comments and the design, for the owning workstream:

- **Ladders and the movement sanity check.** `SurvivalService` counts rising more than
  `JUMP_HEIGHT + 8` (14.5 studs) above the last grounded height as excess on every tick, and
  nothing marks TrussPart climbing as grounded or exempt. Climbing the 48-stud ice wall ladder
  (and possibly the 28-stud ridge ice-step ladder) should accumulate past the 25-stud tolerance
  and snap the player back to the foot. Found by reading the code; the boot test teleports along
  the route, so it does not cover this.
- Wind wall `description` says it shelters "anyone standing in its lee", but the code applies
  wind x0.4 to everyone within 8 studs regardless of wind direction.
- Anyone can pack up anyone's tent and keep the `tent_pack`.
- Both rockfall zones (valley avalanche slope, serac band) telegraph with "ROCKS ARE LOOSENING
  ABOVE YOU".
- The weather `lightning` parameter is not used by anything.
- `ProgressionConfig.XP.SectionComplete` (300) is unused; the summit awards `XP.Summit` (1000).
- `CampKit` builds a `RescueSpawn` part on Base Camp "for evacuations", but nothing reads it;
  evacuees go to their camp's `Spawn`.
- `WorldBuilder` says character spawning waits for the `WorldReady` workspace attribute, but
  nothing reads it; the gate is `Players.CharacterAutoLoads` in the bootstrap.
- DataService tracks `dirty` but autosave saves every session regardless.
- `GameConfig.MAX_PLAYERS_HINT` says the UI uses it; nothing does. Max players must be set in
  Game Settings.
- Snow load on tarp roofs is visual only; it doesn't affect durability.
- Rejoin restore only works on the same server within 600 s; supply allowances reset otherwise.
- `tests/render/render.py`'s docstring mentions a `--check` flag that does not exist (use
  `tests/render/checks.py`), and `docs/previews/README.md` still says new players get the
  daypack (fixed in `InventoryService.setupLoadout`).
