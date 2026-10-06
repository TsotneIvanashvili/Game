# Roadmap

Honest status of the mountain-survival vertical slice. How the systems work is in
[ARCHITECTURE.md](ARCHITECTURE.md).

**Overall: code-complete vertical slice, NOT yet play-tested in Roblox Studio.** Everything below
marked "done in code" compiles with the real Luau compiler, passes selene and StyLua, and (for
the pure logic layer) passes the unit/stress tests in `tests/spec.luau` (45 at time of writing).
The manual Studio test plan is in [TESTING.md](TESTING.md). None of it has been
run inside Roblox yet, so every engine-facing item still carries a "needs Studio testing" caveat.

Status legend

| Status | Meaning |
|---|---|
| Done in code | Implemented end to end (server + client where relevant), not yet run in Studio |
| Done + unit tested | As above, and the logic is covered by `tests/spec.luau` |
| Partial | Some of the checkpoint exists; the gap is listed |
| Not started | No code yet |
| Needs Studio testing | Can only be verified in a running place (physics, feel, replication, DataStores) |

> The design brief itself is not checked into this repository. Checkpoint titles and the slice
> steps below are paraphrased from it; reconcile wording and numbering against the brief.

---

## Development checkpoints

| # | Checkpoint | Status | What exists / what's missing |
|---|---|---|---|
| 1 | Project foundation (Rojo, folder layout, Registry, PlayerStore, remotes, config modules, test tooling) | **Done in code** | `default.project.json`, `rokit.toml`, bootstrap, RemoteGuard, `tests/check.sh` all green |
| 2 | Movement, sprint and stamina | **Done + unit tested**; needs Studio testing | Server sets WalkSpeed/JumpHeight from survival modifiers every 0.2 s; MovementController sends sprint/jump intent. Feel (speeds, FOV, jump cost) untested. No custom animations |
| 3 | Survival stats: hunger, thirst, fatigue, health, oxygen, altitude sickness | **Done + unit tested** | SurvivalModel + SurvivalService; HUD bars; notifications |
| 4 | Temperature, clothing layers, wetness, frostbite | **Done + unit tested** | WarmthModel (per-region), 13 clothing items, fire heat, shelter, frostbite stages |
| 5 | Inventory, backpack tiers, weight and slots | **Done + unit tested** (model, 10k-op stress test); UI needs Studio testing | InventoryService, InventoryController, 4 pack tiers, 130% hard cap |
| 6 | Visible equipment on the character | **Done in code**; needs Studio testing | EquipmentService: clothing shells, pack, harness, stowed axe/rope/tarp/wood, held axe, wet darkening, snow on pack. Greybox only. R15 targeted; on R6, gloves and boots don't show |
| 7 | Climbing (rock, ice with ice axe) | **Done in code**; needs Studio testing | Client motion via AlignPosition/AlignOrientation, server start/tick authority, grip failure. Mantle, latency tolerance (`WALL_PROBE`, `SPEED_TOLERANCE`) and feel are untested |
| 8 | Injuries, fall damage, medical items | **Done + unit tested** | 11 injury types with cure paths; splints, bandages, first aid kit; fall thresholds |
| 9 | Resources: wood, water, food, cooking, boiling | **Done in code** | WoodSource/WaterSource prompts, untreated water sickness, purification, cook/boil/melt snow at fires, thermos |
| 10 | Building: Build Book, campfire, emergency shelter | **Partial** | 4 of 10 recipes implemented (campfire, tarp shelter, wind wall, trail marker); full server validation pipeline; placement ghost. Missing: wind_fire, snow_shelter, rope_anchor, snow_melter, signal_fire, avalanche_shelter |
| 11 | Weather | **Done in code** (graph logic unit tested); visuals need Studio testing | 7-state neighbour graph, blending, forced storm path, elevation-based temperature and rain/snow; WeatherController renders fog/sky/precipitation; lightning is cosmetic only |
| 12 | Natural disasters | **Partial** | Rockfall fully telegraphed and pooled. Avalanche **not started** (design in ARCHITECTURE section 13) |
| 13 | Multiplayer teamwork: downed, revive, carry, give, treat, pings | **Done in code**; needs multi-client Studio testing | RescueService, Give/Treat, PingController, teammate list on HUD, rejoin stash, leave-while-downed = evacuation. Rope teamwork **not started** |
| 14 | Checkpoints, expedition flow, progression | **Done in code** | Camps + logbooks, respawn at last camp, director (snowfall at snowline, forced storm after Ridge Camp), section end + summary, XP/ranks. Blueprint unlocks have no in-game source yet |
| 15 | Saving and loading | **Done in code**; needs live DataStore testing | Session lock, retries, sanitize, read-only fallback, autosave, BindToClose, quick-rejoin handling. Requires a published place with Studio API access |
| 16 | Audio, VFX, art, polish, optimization, QA | **Partial** | AudioController/ConditionController/WeatherController exist but every sound id is empty (game is silent), particles use default textures, all models are greybox, no animations, no profiling, no in-Studio test pass |

---

## Vertical slice: 22-step checklist

The slice is one mountain section: Base Camp -> forest trail -> cliff or safe ramp -> snow slope ->
Ridge Camp -> ice wall or bypass -> Ridge Col. Every step below is implemented in code; **none has
been played through in Studio**.

| # | Step | Systems implementing it | Status |
|---|---|---|---|
| 1 | Join and spawn at Base Camp | WorldBuilder (SpawnLocation), PlayerService, DataService, ProgressionService | Done in code |
| 2 | Pick clothing at the outfitter | CampService prompt -> `OpenPanel` -> PanelController -> `Outfit` -> InventoryService; saved to `profile.loadout` | Done in code |
| 3 | Pick a backpack (slots vs. weight limit) | Same path; pack switch refused if contents don't fit | Done in code |
| 4 | Take food, water and tools | Supply crate (`Supply`, per-player allowance), outfitter one-off tools, StarterPack | Done in code |
| 5 | Check pack weight and contents | InventoryController (Tab / I), `Weight`/`WeightLimit` attributes on the HUD | Done in code |
| 6 | See your gear on your character (and on teammates) | EquipmentService | Done in code (greybox) |
| 7 | Hike the forest trail | WorldLayout ForestTrail, SurvivalService exertion, zones | Done in code |
| 8 | Gather wood | ResourceService WoodSource prompt; wood bundle appears on the pack | Done in code |
| 9 | Manage hunger, thirst, stamina and fatigue; eat and drink | SurvivalModel, InventoryService Use, WaterSource Fill/Drink, purification tablets | Done + unit tested |
| 10 | Choose a route: technical cliff or safe ramp | WorldLayout (Cliff with rest ledge, SafeRamp, Ravine fallback) | Done in code |
| 11 | Climb the cliff on stamina | ClimbingController + ClimbingService, grip failure at 0 stamina | Done in code; needs feel testing |
| 12 | Risk a fall and an injury; treat it | SurvivalService fall tracking, InjuryModel, splint/bandage/first aid kit | Done + unit tested |
| 13 | Weather turns: snow rolls in at the snowline | ExpeditionService director -> WeatherService.force -> WeatherController | Done in code |
| 14 | Get cold with altitude, wind and wet clothes; frostbite warnings | WarmthModel, SurvivalService, ConditionController, HUD | Done + unit tested |
| 15 | Build a campfire: warm up, dry off, cook, boil water | BuildingService, BuildBookController, InventoryService cook/boil | Done in code |
| 16 | Rockfall in the East Gully: warning, boulders, injuries | DisasterService | Done in code |
| 17 | A teammate goes down: revive, carry, treat, or they evacuate | RescueService, InventoryService Treat, MovementController (X), HUD downed overlay | Done in code; needs multi-client testing |
| 18 | Reach Ridge Camp and sign the logbook | CampService, ProgressionService XP, new respawn point | Done in code |
| 19 | The storm is forced in: shelter in the cabin or build a tarp | ExpeditionService -> WeatherService.force("Storm"), cabin ShelterVolume, tarp shelter durability/reinforce | Done in code |
| 20 | Ice wall with a held ice axe, or the longer bypass | ClimbConfig ice materials, Glacier IceWall, IceBypass slab, held-item check | Done in code |
| 21 | Reach the Ridge Col and see the expedition summary | CampService SectionEnd -> ExpeditionService.sectionComplete -> SummaryController | Done in code |
| 22 | Progress is saved (XP, rank, totals, loadout) | DataService, ProgressionService | Done in code; needs live DataStore testing |

---

## Next steps

Highest priority first.

1. **Studio play-test pass** (the gate for everything else). Build with Rojo, run solo and a
   6-player local server, walk all 22 slice steps, and log every bug. Specifically verify:
   climbing feel and mantle, carry welds, fall damage thresholds, build placement on terrain,
   rockfall boulder paths, weather visuals, DataStore session locking across two servers.
2. **Tune the server movement sanity check** (SurvivalService; see ARCHITECTURE section 14)
   against real play: knockback from boulders, steep slopes, jumping off walls, lag spikes.
3. **Avalanche**: second disaster, following the design in ARCHITECTURE section 13
   (`AvalancheZone` tag, telegraph, sweep, buried/dig-out state, `avalanche_shelter` recipe).
4. **Rope teamwork**: implement `rope_anchor` (recipe exists, `implemented = false`), fixed lines
   that make a climb section cheaper for the team, roped travel on the glacier (a falling
   teammate is held by the others), belay assist on climbs.
5. **Crampons**: new item (spec already in `docs/ASSET_SPECS.md`); faster, cheaper ice climbing
   and no slipping on ice/glacier terrain; EquipmentService visual on the boots.
6. **More zones**: `ZoneDefs` already defines Frozen Ridge, Glacier, High Altitude and Summit;
   extend `WorldLayout` upward with a third camp, use `XP.Summit` and `totals.summits`, and wire
   the unused `woodAbundance`/`snowCover` zone fields into resource placement.
7. **Animations**: climbing, crawling while downed, being carried, resting/sitting by the fire,
   building, eating/drinking, shivering. Currently everything uses default character animations.
8. **Real art**: replace AssetFactory greybox builders with meshes per `docs/ASSET_SPECS.md`,
   keeping the anchor names (`Axe`, `Rope`, `Tarp`, `Wood`); real item icons; snowflake, raindrop,
   breath and dust particle textures.
9. **Audio IDs**: fill every key in `src/client/AudioConfig.luau` (Wind, Rain, Blizzard, Rumble,
   Thunder, FireCrackle, HeavyBreathing, Heartbeat, Shivering, SnowStep, RockStep). Until then
   the game is silent.
10. Remaining Build Book recipes, and an in-game source for blueprint unlocks
    (`ProgressionService.unlockBlueprint` is never called yet).
11. Settings UI: `profile.settings.cameraShake` is saved but nothing reads or changes it.
12. Profiling with 6 players (MicroProfiler, network stats), then decide whether
    `BuildingService.environmentAt` needs a spatial grid.

---

## Known gaps found while documenting

Small mismatches between code, comments and the design, for the owning workstream:

- Wind wall `description` says it shelters "anyone standing in its lee", but the code applies
  wind x0.4 to everyone within 8 studs regardless of wind direction.
- `WeatherDefs` says one storm is "a thunderstorm in the forest and a blizzard on the ridge", but a
  fully blended Storm is -1 C at Base Camp (9 C base - 10 C offset), below the 1 C rain/snow
  split, so it is a blizzard everywhere and lightning never shows at full storm strength.
- Lightning has no gameplay effect (client flashes only).
- `XP.FirstShelter` (25) in ProgressionConfig is not read; BuildingService hard-codes 25.
  `XP.Summit` is unused (no summit in the slice).
- DataService tracks `dirty` but autosave saves every session regardless.
- `GameConfig.MAX_PLAYERS_HINT` says the UI uses it; nothing does. Max players must be set in
  Game Settings.
- `SectionEnd` parts are only collected at server start (no `GetInstanceAddedSignal`), unlike the
  other tags.
- Snow load on tarp roofs is visual only; it doesn't affect durability.
- Rejoin restore only works on the same server within 600 s; supply allowances reset otherwise.
- The comment for `PingBroadcast` in `Remotes.luau` lists two arguments; three are sent.
