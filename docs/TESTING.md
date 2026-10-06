# Testing

This document covers how the mountain-survival vertical slice is verified:

1. [Automated checks](#1-automated-checks) (run on any machine, no Roblox needed)
2. [Manual Studio test plan](#2-manual-studio-test-plan) for the vertical slice
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

`tests/check.sh` is the full local gate. It runs four stages in order and stops at the first one that fails (`set -e`):

| Stage | Command | What it catches |
|---|---|---|
| **Compile** | `luaurun tests/compile_check.luau <file>` for every `*.luau` under `src/` and `tests/` | Loads each file with the **real Luau compiler** (Luau 0.663, vendored by `mlua`). This catches syntax that StyLua accepts but Roblox rejects, such as ambiguous call syntax across lines, bad `if`-expressions, or a stray `continue`. It only compiles, so it does not run the file and does not type-check it. Errors print as `COMPILE ERROR: <file>` followed by the compiler message. |
| **Lint** | `selene src tests` | Uses `selene.toml` with `std = "roblox_lite"` (`roblox_lite.yml`). This is a small hand-written Roblox std that works offline. It declares the Roblox globals (`game`, `workspace`, `Instance`, `Vector3`, `task`, `Enum`, …) as `any`, plus the test-host globals `__loadfile` and `ROOT`. It catches undefined globals, unused variables, unreachable code and similar issues. **It cannot catch misspelled Roblox API members** (`Instance.nwe`, `humanoid.WalkSpeeed`), because every Roblox global is `any`. With network access you can switch to `std = "roblox"` for full API typing. `shadowing` and `multiple_statements` are allowed. |
| **Format** | `stylua --check src tests` | Checks formatting against `stylua.toml`: tabs, 120 columns, Unix line endings, double quotes, parentheses always. Run `stylua src tests` to fix. |
| **Unit / stress** | `tests/run.sh` → `luaurun tests/spec.luau <repo root>` | Runs the pure-logic suite in a standalone Luau VM. See 1.3. Prints `N passed, M failed` and lists each failure. A non-zero failure count raises an error, so the script exits non-zero. |

Run it from anywhere:

```sh
tests/check.sh          # everything
tests/run.sh            # unit tests only (fast)
```

Prerequisites on `PATH`: `luaurun` (built as described below), `selene` and `stylua`. The repo pins tool versions in `rokit.toml` (`rokit install`): selene 0.27.1, stylua 2.0.2, rojo 7.4.4. Newer local versions (for example selene 0.31 or stylua 2.5) usually agree, but a StyLua version bump can reformat code. CI and pre-merge checks should use the pinned versions.

A clean run currently ends with:

```
compile: ok
Results:
0 errors
0 warnings
0 parse errors

44 passed, 0 failed
```

### 1.2 Building `luaurun`

`luaurun` is a very small Luau host written in Rust on top of the [`mlua`](https://crates.io/crates/mlua) crate. The `luau` and `vendored` features compile Luau from source, so no system Lua is needed. The host does three things:

* loads and runs the script given as the first argument,
* exposes `__loadfile(path)`, which compiles a file and returns it as a function without running it (the test harness uses it to implement `require`, and `compile_check.luau` uses it to compile-check a file),
* sets a global `ROOT` to the second argument (default `"."`).

**Requirements:** a Rust toolchain (built and verified with rustc/cargo 1.97; any recent stable should work) and a C++ compiler (`g++` or `clang++`), because `luau0-src` builds the Luau VM and compiler from C++ source. The first build takes about 1 minute.

```sh
mkdir -p luaurun/src && cd luaurun
# write Cargo.toml and src/main.rs as below, then:
cargo build --release
cp target/release/luaurun ~/.cargo/bin/      # or: cargo install --path .
luaurun --help 2>/dev/null; echo ok          # (no usage text; it panics without args, that's expected)
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

// Tiny Luau host for running pure-logic unit tests outside Roblox.
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

Versions resolved in the reference build: `mlua 0.10.5`, `mlua-sys 0.6.8`, `luau0-src 0.12.3+luau663`.

### 1.3 The unit / stress suite (`tests/spec.luau`)

`tests/harness.luau` builds a fake `script` instance tree mapped onto the filesystem, so `require(script.Parent.X)` inside shared modules resolves to `src/shared/.../X.luau`. It also stubs the two Roblox datatypes that the config modules build at load time (`Vector3.new` with `+`/`-`/`Magnitude`, and `Color3.new`/`fromRGB`). The suite currently has 44 tests:

| Area | What is covered |
|---|---|
| **Config integrity** | Every item def is well formed. Loadout, outfitter and supply tables only reference real items. Recipes reference real items, and every implemented recipe can be built from items the slice provides. The weather graph is connected and every neighbour exists. Zones are ordered top-down. Rank lookup works. |
| **Warmth** (`WarmthModel`) | Layering: insulation stacks, and wind and water protection come from the best layer. A wet cotton tee under a parka still costs warmth. Starter clothes stay comfortable in the forest for 10 minutes. A blizzard in starter clothes gives frostnip within about 3 minutes. Light snow is uncomfortable but causes no frostbite within 6 minutes. Overdressing while sprinting causes sweating, and standing by a fire does not. Expedition gear keeps the core warm for 5 minutes in a blizzard. A fire rescues a freezing player in under a minute. Fire heat falls off to zero at its radius. Rain soaks a fleece, a shell sheds it, and fire dries it. |
| **Stamina / survival** (`SurvivalModel`) | Sprinting drains stamina and locks out at 0, and recovery unlocks it. Regen waits for the regen delay. Hunger, thirst, cold, fatigue, altitude and weight each reduce regen. Fatigue and starvation shrink max stamina. A light pack has no effect, and an overloaded pack slows you and blocks climbing. Oxygen floors correctly. Starvation and dehydration hurt, and nothing goes NaN over a long cold run. Critical cold knocks you unconscious. Frostbite escalates, a first aid kit downgrades it, and warmth clears frostnip. The hand warmer buff works. Hot stew warms, and eating clamps at 100. |
| **Injuries** (`InjuryModel`) | `useWouldHelp` refuses a pointless splint and accepts one for a sprain. A broken leg blocks climbing and sprinting, and a splint improves speed but not climbing. A broken leg heals only with camp rest. A bandage stops bleeding. Serialization is stable. |
| **Inventory** (`InventoryModel`) | Stacks merge up to maxStack, then use new slots. The slot limit holds and partial adds report the true count. Bad quantities are rejected. Containers never merge and carry their water weight. Snapshots don't alias server state. Recipe removal is atomic. `removeFromStack` clamps and deletes empty stacks, and a double remove (dupe attempt) gets nothing. **Stress:** 10,000 random add/remove/removeAll operations keep the slot limit, per-stack quantity bounds, unique uids and non-negative weight. |
| **Weather** (`WeatherModel`) | A forced storm from Clear walks `Cloudy>LightPrecip>HeavyPrecip>Storm`. Blend endpoints, midpoint and clamping work. `pickNext` only returns neighbours. Temperature: snow at the ridge in a storm, rain at base camp in clear weather. |

**What the suite cannot cover.** Anything that touches Roblox engine APIs or runs inside a live DataModel is out of reach. That means every server service and client controller. In particular:

* `Players`, characters, `Humanoid` (health, WalkSpeed, JumpHeight, PlatformStand), respawn and `LoadCharacter`
* `workspace:Raycast`, `GetPartBoundsInBox`, terrain materials. This covers ground checks, climbing surface classification, build placement, fall tracking, water volumes and world generation (`WorldBuilder`, `AssetFactory`)
* physics: boulders, carry welds, climbing `AlignPosition`, network ownership
* `ProximityPrompt` triggering and range checks (`PromptUtil`)
* `RemoteEvent`/`RemoteFunction` traffic, `RemoteGuard` rate limiting and dispatch, and replication of attributes and parts
* `DataStoreService`, session locking, `BindToClose`
* `CollectionService` tags, `task.delay` timing, and every UI
* `Validate.luau` is pure, but it is **not unit-tested yet**: it branches on Roblox `typeof()` returning `"Vector3"`/`"CFrame"`, which the harness doesn't stub. Adding a `typeof` shim to the harness would make the remote schemas testable offline, and is recommended.

Everything in that list is covered by the manual plan in sections 2 to 5.

---

## 2. Manual Studio test plan

### 2.0 Setup, conventions and helpers

**Build the place.** Run `rojo serve` and connect the Rojo plugin in an empty baseplate. Alternatively, run `rojo build -o MountainSurvival.rbxl` and open the file. The server generates the map from `WorldLayout` on start, unless a `Workspace.Mountain` model already exists. Output should print `[Server] world generated in X.XXs` and then `[Server] 15 services started in X.XXs`.

**Pre-flight (blocking).** Before running anything else, confirm all of the following:

* [ ] Output shows **no errors** on Play (server or client).
* [ ] `ReplicatedStorage.Remotes` exists and contains the 13 client→server remotes and 8 server→client remotes listed in `src/shared/Net/Remotes.luau`. `ReplicatedStorage.WorldState` exists.
* [ ] The client actually boots its controllers: a client entry script under `StarterPlayerScripts.Client` requires and Inits/Starts the controllers. The HUD (bottom-left stat panel, top-right zone/elevation readout, bottom hint line `Tab pack · B build · C climb · Shift sprint · G ping`) is visible. If it isn't, stop and file a blocker.
* [ ] Every key used below is bound: Tab/I, B, C, Shift, Space, G, X, plus E/F/Q on prompts. The client was still being written when this plan was drafted, so check each binding exists before relying on it.
* [ ] The reset button is disabled. `MovementController` turns it off, because resetting would skip the survival consequences.

**Conventions**

* Coordinates are `(X, Y, Z)` in studs, taken from `src/shared/Config/WorldLayout.luau`. **+Z is uphill**, +Y is up and X is lateral. The Y values in `WorldLayout` are the designed surface heights; the real ground can be a few studs off, so add +5 to Y when teleporting.
* The HUD elevation is `1200 + 8 × Y` metres. Base Camp is about 1200 m, the cliff base about 1680 m, the cliff top about 2120 m, Ridge Camp about 2400 m and the Ridge Col about 3280 m.
* Zone by Y: Base Forest < 30, Rocky Forest 30–95, Alpine Meadow 95–135, **Snowline ≥ 135**.
* Live state: select your `Player` in Explorer. The **Attributes** section of Properties updates live with `Stamina`, `MaxStamina`, `Hunger`, `Thirst`, `Fatigue`, `Warmth`, `WarmHands`/`WarmFeet`/…, `Wetness`, `ColdLevel`, `Exertion`, `Injuries`, `Zone`, `ElevationM`, `TempC`, `WindMs`, `Weather`, `InShelter`, `NearFire`, `CanSprint`, `CanClimb`, `ClimbSpeed`, `Climbing`, `Resting`, `Downed`, `BleedOut`, `Carrying`, `CarriedBy`, `Checkpoint`, `XP`, `Rank`, `Weight`, `WeightLimit`, `HeldItem` and `BuildingUntil`. Weather state lives on `ReplicatedStorage.WorldState`: `WeatherFrom`, `WeatherTo`, `WeatherBlend`, `WindMs`, `Precipitation`, `Fog`, `Cloud` and `TempOffsetC`.

**Key map:** Tab / I = pack. B = Build Book. C = climb grab / let go. W/S/A/D move on the wall. Space = jump off the wall. Shift = sprint (hold). G = ping. X = set down a carried player. Prompts use **E** (primary), **F** (secondary) and **Q** (cook/boil). In placement mode: R rotates, left-click places, right-click / Esc / B cancels.

**Server command-bar helpers.** In Studio Test, switch the view to *Server* and run these in the command bar:

```lua
-- teleport (replace Player1 / coordinates)
game.Players.Player1.Character:PivotTo(CFrame.new(0, 155, 775))
-- low health, so the next hit downs you
game.Players.Player1.Character.Humanoid.Health = 5
-- disconnect a player
game.Players.Player2:Kick("test disconnect")
-- count BaseParts
local n=0 for _,d in workspace:GetDescendants() do if d:IsA("BasePart") then n+=1 end end print(n)
```

> Don't set `Humanoid.Health = 0` from the command bar. That kills the character outright and bypasses the downed system (see E-12). Requiring a service ModuleScript from the command bar may give you a **separate copy** of the module, because the command bar can use its own require cache. Calls such as `DisasterService.forceRockfall()` may then do nothing. Check this in 2.10 before relying on any service hook.

**Map landmarks** (from `WorldLayout`)

| Place | Coordinates / extent |
|---|---|
| Base Camp spawn | (0, 0, −58). The SpawnLocation is here. |
| Base Camp fire / logbook | (0, 0, −28) / (−12, 0, −14) |
| Supply crate "BaseCamp" / Outfitter | (38, 0, −40) / (24, 0, −58) |
| Water pump (treated) / cabin | (−26, 0, −22) / (−48, 0, −62), 26×12×20 |
| Wood near base | (−40, 0, 40) 4 wood, (55, 0, 70) 4 wood. Respawn after 180 s. |
| Stream (untreated) access points | (−75, 18, 130), (−75, 40, 270), (−75, 56, 380). The trench runs along X = −75, 8 wide, from Z 40 to 400. |
| Trail end → cliff base | Trail runs (0, 0, 60) → (0, 60, 400). Cliff base flat is at Y 60, Z 400–450. |
| **Rock cliff** ("Cliff" block) | Face at **Z = 450**, X −100…100, rising from **Y 60 to Y 115** (55 studs). Terrain Rock. |
| **Rest ledge** | Centre (0, 86, 446.5), X −18…18. Top at Y 88 (28 studs up the face). Slate (climbable). |
| Upper plateau (cliff top) | (0, 115, 500…560) |
| Snow slope | (0, 115, 560) → (0, 150, 720). Snowline (Y 135) is crossed at about Z 650. |
| Safe ramp (east) | X = 150, width 40, (150, 60, 450) → (150, 150, 720), about 18°. Snowline at about Z 675. |
| **EastGully rockfall zone** | Box centred (150, 115, 600), size (70, 90, 130): **X 115–185, Y 70–160, Z 535–665**. Release points (182, ~150, 560), (182, ~158, 600), (182, ~165, 640). Push −X. |
| Ravine (emergency route) | Floor along X = 115, (115, 40, 450) → (115, 150, 790) |
| **Ridge Camp** | Centre (0, 150, 775), spawn (0, 150, 786), fire (0, 150, 768), logbook (14, 150, 756), supply crate "RidgeCamp" (34, 150, 778), meltwater (treated) (−16, 150, 760), cabin (−44, 150, 796), woodpile (−120, 150, 800): 6 wood, **never respawns**. |
| Upper snow | (0, 150, 830) → (0, 230, 1000) |
| **Ice wall** (Glacier) | Face at **Z = 1000**, X −45…45, from about Y 230 to Y 262 (about 30 studs) |
| Ice bypass | X = 92, (92, 230, 990) → (92, 260, 1080) |
| **Ridge Col / section end** | (0, 260, 1070), radius 22 |
| Safety net | Below Y −30 you are recovered to your checkpoint after 3 s. World floor top is at Y −40. |

**Baseline loadout weight.** The starter kit is a cotton tee, fleece, liner gloves, hiking pants, trail runners, a daypack, a 1 L treated bottle and 2 energy bars. It totals about **3.7 kg**. The daypack limit is **12 kg** (slots 10) and the hard cap is 130%, so **15.6 kg**. Wood weighs 1.2 kg, rope 2.5 kg and a tarp 1.1 kg.

---

### 2.1 Spawn & loadout

| ID | Setup | Steps | Expected |
|---|---|---|---|
| SP-01 | Fresh profile (API access off, or a new test account) | Press Play. | You spawn on the plank SpawnLocation at about (0, 0, −58). HUD shows `Base Forest · 1200 m`. Health, Stamina and Warmth bars are always shown, and Food/Water/Energy/Oxygen are hidden while full. The pack readout shows about `Pack 3.7 / 12 kg`. |
| SP-02 | — | Open the pack (Tab, then I). | Worn: Base layer *Cotton tee*, Jacket *Fleece*, Gloves *Liner gloves*, Pants *Hiking pants*, Boots *Trail runners*. Head and Face are empty. Contents: water bottle `1000 / 1000 ml · treated`, energy bar ×2. Footer shows weight and slots `/10`. Tab and I both toggle the panel. |
| SP-03 | — | Walk to the outfitter (24, 0, −58) and press **E** "Change gear". | The outfitter panel opens with all 21 stock items, all available at rank 1. Walking more than 14 studs away closes the panel. |
| SP-04 | At outfitter | Take the ice axe, lighter, thermos and water bottle. | You receive the ice axe, lighter and thermos once each. A second take gives "You already took one this expedition." The **water bottle** is refused immediately because the starter bottle counts as taken. |
| SP-05 | At outfitter | Pick *Insulated parka*, then *Pack (medium)*. | The parka is worn at once (it replaces the fleece; the old jacket is not added to the pack). "Switched to …" for the pack. `WeightLimit` becomes 18 and slots 14. The character visuals update (see 2.4). |
| SP-06 | At outfitter, pack holding 11+ stacks | Try to switch back to the daypack. | "Too many items for that pack. Drop some first." If the stacks fit but the weight exceeds 12 × 1.3 kg: "That pack can't carry what you have." |
| SP-07 | At the Base Camp crate (38, 0, −40) | Press **E** "Open supply crate" and take items repeatedly. | The panel shows remaining counts: energy bar 4, chocolate 2, trail mix 2, dried meat 2, canned stew 2, emergency ration 1, electrolyte 1, bandage 3, splint 1, first aid kit 1, hand warmer 3, purification tabs 4, rope 2, tarp 1. Once you exceed an allowance: "You've taken your share of that." A full pack or the weight cap gives "No room in your pack (or too heavy)". The allowance is per player per expedition and is not reset by respawning. |
| SP-08 | Far from any crate | (Exploit check, see E-07) | — |

### 2.2 Survival stats

| ID | Setup | Steps | Expected |
|---|---|---|---|
| SV-01 Stamina drain | Base Camp, flat ground | Hold **Shift** and run. | `Exertion` = `sprint`, speed rises from 14 to 22 studs/s and the FOV widens slightly. Stamina drains at about 11/s (about 9 s from 100 to 0). Food and Water drain faster: 2.2× while sprinting versus 1.2× walking. |
| SV-02 Lockout | Continue SV-01 | Keep holding Shift after Stamina reaches 0. | "You're out of breath." appears once (15 s cooldown). You drop to walking speed even with Shift held. `CanSprint` and `CanClimb` = false until Stamina recovers to **25**. Regen starts 1 s after you stop spending and runs at about 14/s, so the lockout lasts about 3 s. |
| SV-03 Jump cost | — | Jump repeatedly. | Each jump costs 9 stamina. Below 9 stamina, `JumpHeight` is 0 and you can't jump. |
| SV-04 Cold at snowline | Starter clothes. Weather Light Snow: reaching Y ≥ 135 forces it, see WX-03. | Stand idle at about (0, 142, 670) for 5 minutes. Watch `WarmHands`, `WarmFeet` and `Warmth`. | `TempC` is around −1 °C and `Weather` shows *Light Snow*. Feet and hands cool fastest. Expect the "You're getting cold." (Moderate, warmth < 50) warning within a few minutes, plus region warnings such as "You can't feel your toes." when a region drops below 30. **No frostnip** within 6 minutes of light snow (a unit test asserts this). The HUD warmth bar turns from orange to pale to blue as warmth drops. Swapping in alpine boots and insulated gloves visibly slows the drop. |
| SV-05 Cold in blizzard | Ridge Camp after the storm (WX-02), starter clothes | Stand outside the cabin, away from the fire. | `Weather` = *Blizzard*, `TempC` ≈ −9 °C, wind about 20 × 1.25 = 25 m/s. Frostnip (hands, feet or face) within about 3 minutes, then Severe and Critical warnings. At Critical warmth (< 12) you take 0.6 HP/s, `CanClimb`/`CanSprint` turn off, and after 20 s at Critical you are **downed by hypothermia** (see 2.11). |
| SV-06 Wetness in rain | Base Camp while it is *Light Rain*: one player reaches the snowline, so it is 7 °C at Y 0 | Stand in the open. Watch `Wetness`. | Wetness rises at about 0.005/s (fleece and hiking pants shed little). The HUD sub-line shows `damp` after about 50 s and `soaked` after about 2 minutes. Heavy Rain roughly doubles that. Wet clothes visibly darken (see EQ-07). A shell jacket cuts the rate by roughly two thirds. Stepping inside the cabin (`InShelter` = true) stops the gain and you slowly dry. |
| SV-07 Standing in water | Stream at (−75, 18, 130) | Stand in the stream trench. | Wetness rises fast (+0.25/s, soaked within about 4 s). Feet cool faster (contact chill). |
| SV-08 Sweating in parka | Base Camp, clear weather, insulated parka worn | Sprint or walk continuously for 2 minutes. Do not stand near a fire. | Wetness rises from the inside: torso felt temperature is well above 30 °C. Expect `damp` (> 0.25) after about 1 minute of walking and sooner when sprinting. Standing still stops the gain. Standing by a fire does **not** cause sweating. |
| SV-09 Hunger/thirst | — | Watch Food and Water over 5 minutes of walking. | Hunger drains in about 30 min idle and thirst in about 22 min idle, both faster with exertion and altitude. At < 25: "You're very thirsty." / "You're hungry…" (60 s cooldown) and slower stamina regen. At 0 you lose health over time. |
| SV-10 Natural healing | Health < 100, Food and Water > 50 | Stand still, then rest by a fire (E). Then repeat with Food or Water < 50. | Health regenerates at 0.15 HP/s, or 4× while resting. With Food or Water ≤ 50 there is **no** regen. Roblox's default `Health` regen script is removed from every character (check Explorer: no `Health` Script under the character), so health never ticks up 1%/s on its own. |
| SV-11 Oxygen | Climb above Y 162 (> 2500 m) | Watch the Oxygen bar. | The Oxygen bar appears and drops gradually with height. Stamina costs rise and regen slows. Below 80: "LOW OXYGEN. Pace yourself." Above 3000 m (Y ≥ 225, near the ice wall) altitude sickness starts building. |

### 2.3 Inventory

| ID | Setup | Steps | Expected |
|---|---|---|---|
| IN-01 Use food | Hunger < 100 | Pack → energy bar → **Use**. | Hunger rises, the stack decrements, toast "Used Energy Bar.", and `itemsConsumed` increments (seen in the summary). Using food at 100 hunger still works, because hunger effects always "help". |
| IN-02 Pointless use | No injuries, full health | Use a splint. | "That wouldn't help right now." The item is **not** consumed. |
| IN-03 Drink treated | Bottle with treated water | Use (Drink) the bottle. | 250 ml per sip, +22 thirst per full sip. The bottle line updates (`750 / 1000 ml · treated`). An empty bottle gives "Water Bottle is empty." |
| IN-04 Drink untreated | Fill the bottle at a stream point (−75, 18, 130): **E** "Fill bottles", hold 1 s | Drink it. Repeat several times. | Fill toast: "Filled X L. Treat or boil it before drinking." The bottle shows **UNTREATED**. Each sip has a **35%** chance of *Stomach Upset*: "That stream water didn't sit well…". Drinking straight from the stream (**F**, hold 0.5 s) also gives +20 thirst with the same 35% risk. |
| IN-05 Mixing | Half-full treated bottle | Top up at the stream. | The whole bottle becomes UNTREATED (mixing contaminates it). |
| IN-06 Purify | Untreated water in the pack, purification tabs | Use the tabs. | "Water treated. Safe to drink." One tab is consumed and one container becomes treated. With no untreated water: "You have no untreated water." and nothing is consumed. |
| IN-07 Give | 2 players within 10 studs | P1: select an energy bar → **Give P2**. | The Give button only lists teammates within 10 studs. One unit moves per click for stackables, and the whole item for bottles. P2 gets "P1 gave you Energy Bar." If P2's pack is full or too heavy: "P2's pack is full or too heavy." and P1 keeps the item. |
| IN-08 Give out of range | P2 walks away during the click | Click Give after P2 is 11+ studs away. | "Get closer to P2." and nothing moves. |
| IN-09 Treat teammate | P2 has *Bleeding* (rockfall, see RF-03) or a *Sprained Ankle* (fall, see CL-05). P1 has a bandage or splint. | P1: bandage → **Treat P2**. | "Treated P2." P2 sees "P1 treated you with a Bandage." The injury is removed or marked splinted in P2's HUD injury row. If P2 doesn't need it: "P2 doesn't need that." and nothing is consumed. |
| IN-10 Drop / pick up | — | Drop 1 energy bar, then drop all of another stack. Pick both up again (**E**). | A small bundle appears about 2 studs in front of you on the ground. Pick-up takes a 0.3 s hold for small bundles and 1.5 s for big ones (3+ stacks or an evacuated pack). "Dropped." Picking up restores the items, and the bundle disappears when empty. Unclaimed bundles despawn after 10 minutes. |
| IN-11 Overweight | Daypack. Gather wood at (−40, 0, 40) and (55, 0, 70). | Gather wood one log at a time (E, hold 1.5 s). | About 7 wood (about 12.1 kg): "Your pack is overloaded. You're slow and tire fast." and the weight label turns red. About 8 wood (> 13.2 kg, ratio > 1.1): sprint blocked. About 9 wood (> 13.8 kg, ratio > 1.15): `CanClimb` = false. The **10th** wood is refused with "Your pack is full or too heavy for more wood." (hard cap 15.6 kg). Movement slows as the ratio climbs. |
| IN-12 Slot limit | Daypack with 10 different stacks | Take an 11th item type from the crate. | Refused ("No room…"). Existing stacks still merge up to maxStack (energy bar 10, wood 12). |
| IN-13 Wear from pack | Clothing in the pack (e.g. a jacket you unequipped) | Pack → **Wear**. Then click **x** on a worn slot. | The item is worn and the old one goes into the pack. If the pack is full: "No room in your pack for your old …" and nothing changes. Unequip moves the item into the pack, or "No room in your pack." |
| IN-14 Hold / stow axe | Ice axe in the pack | **Hold**, then **Stow**. | `HeldItem` = `ice_axe`, and the axe moves from the pack to the right hand (EQ-04). Stow reverses it. |

### 2.4 Equipment visuals

Check every visual from the player's own view **and** from a second client, because the visuals are server-built and must replicate.

| ID | Steps | Expected |
|---|---|---|
| EQ-01 Pack tiers | At the outfitter, switch daypack → medium → large → expedition. | Four distinct pack sizes and colours: Small blue, Medium red, Large green, Expedition orange. Each has harness straps over the shoulders. A **hip belt appears on Medium and above**, not on Small. The pack sits on the back and doesn't clip through the torso. |
| EQ-02 Stowed gear | Carry an ice axe (not held), rope, a tarp and wood. | Axe in the pack's axe loop, an orange rope coil under the lid, the tarp roll under the base, and a wood bundle on the side. The wood bundle has **3 sizes**: 1–2 wood, 3–5, 6+. Each part disappears when the item leaves the pack. |
| EQ-03 Rebuild only on change | Use energy bars repeatedly. | No visible flicker of the gear: food changes don't alter the visual signature, so there is no rebuild. |
| EQ-04 Held axe | Hold the ice axe. | The axe appears in the **right hand** with its head forward and vanishes from the pack loop. Stow puts it back on the pack. |
| EQ-05 Clothing shells | Cycle base layer, jacket, gloves, pants and boots at the outfitter. | Fabric-coloured shells over the covered body parts. The **base layer only shows when no jacket is worn**. Jackets have a zip and chest pocket. Shell jacket and parka have a **hood** behind the neck. Boots have dark soles. Works on both R15 and R6 avatars (R6 uses Torso/Left Arm/…). |
| EQ-06 Headwear | Wear a wool beanie, then add a balaclava. Use an avatar with a hat and hair. | Beanie and balaclava shells appear. Hat and hair accessories are **hidden** while a beanie is worn and restored when it is removed. Accessories that load late (after spawn) are hidden too. |
| EQ-07 Wet darkening | Get soaked (SV-06 / SV-07). | Clothing shells **and the pack body** darken in steps, up to about 35% darker at full wetness, and brighten again as you dry. |
| EQ-08 Snow on pack | Stand outside in falling snow at the snowline or Ridge Camp. | A snow cap fades in on the pack lid (full in about 50 s in a blizzard, about 2.5 min in light snow). It doesn't build up while `InShelter`, and melts slowly afterwards, faster near a fire. |
| EQ-09 Respawn | Get evacuated (RS-06), or respawn another way. | Gear is rebuilt on the new character about 0.5 s after spawn and again once the appearance loads. There are no duplicate Gear folders. |

### 2.5 Climbing

| ID | Setup | Steps | Expected |
|---|---|---|---|
| CL-01 Start on rock | Walk to the cliff base at about (0, 61, 446). Face the cliff (+Z). | Press **C**. | You latch onto the wall. `Climbing` = true and the status line shows "Climbing · W/S up/down · A/D sideways · Space jump off · C let go". Climb speed is 6 studs/s, reduced by glove mobility and injuries. Stamina drains at about 7/s (base rate × climb cost multipliers). |
| CL-02 Bad target | Face a grass slope or a tree. | Press C. | Toast "You can't climb that." or "Face a rock wall to climb." No server climb state. |
| CL-03 Rest ledge | Climb up at X between −18 and 18. | Climb to Y about 88 and step onto the Slate ledge (or mantle onto it). Let go with C. Stand there for 10 s. | Climbing the ledge's own face is allowed (Slate counts as rock). You can stand on the ledge, `Climbing` = false, and stamina regenerates. Press C facing the cliff again to resume. Total climb is about 55 studs, about 9 s and about 65 stamina from fresh, so the ledge is optional when fresh and needed when tired. |
| CL-04 Mantle at top | Climb to the lip at Y about 115. | Keep holding W. | When your head clears the lip you mantle up and over onto the plateau (about 0.5 s). The climb ends without a "grip fails" toast and **without fall damage**. |
| CL-05 Grip failure | Sprint until stamina is about 20, then start climbing (it needs ≥ 15). Or do repeated up/down laps on the face. | Keep climbing until stamina hits 0. | "Your grip fails!" and you fall. Fall damage is measured from the peak height. Over 18 studs: 2.2 HP per stud above 18. Over 24 studs: 50% chance of *Sprained Ankle*. Over 38 studs: *Broken Leg* (60%) or *Sprain*. 75+ studs: *Broken Leg* and **downed**. You also get a camera shake and lose 15 stamina. Example: a fall from the ledge (about 28 studs) costs about 22 HP. A fall from the top (about 55 studs) costs about 81 HP. |
| CL-06 Jump off | Mid-wall | Press **Space**. | You push off the wall (back and up) and fall normally. Fall damage applies from the peak. |
| CL-07 Climb down | Near the bottom | Hold S. | When the feet find ground you step off automatically. |
| CL-08 Ice wall without axe | Walk up the upper snow to the ice wall face at about (0, 232, 997), facing +Z. | Press C with the axe in the pack but not held. | Toast "Ice. Hold an ice axe to climb it (open your pack)." If the client is bypassed, the server says "Ice. You need to hold an ice axe to climb it." |
| CL-09 Ice wall with axe | Hold the ice axe (IN-14). | Press C and climb about 30 studs to the col. | Climbing works. Mantle onto the Ridge Col at Y about 260. |
| CL-10 Blocked states | Each of these in turn: carrying a player, downed, overloaded (> 1.15), Critical cold, broken leg, exhausted lockout | Press C. | "You're in no shape to climb (injury, cold or an overloaded pack)." (or the server equivalent). No climb starts. |
| CL-11 Ice bypass | — | Walk up the bypass ramp at X = 92 from Z 990 to 1080. | Reaches the col without climbing, but takes longer. |
| CL-12 Lag tolerance | Studio Settings → Network → *Incoming Replication Lag* 0.3 s | Climb the cliff normally. | No spurious stops. The server speed check allows 2.2× climb speed + 1.5 studs per tick. Any unexplained drop (a silent `ClimbForceStop`) is a bug. |

### 2.6 Building

| ID | Setup | Steps | Expected |
|---|---|---|---|
| BD-01 Campfire | Lighter + 3 wood, flat forest ground | Press **B**, pick *Campfire*, aim (the green ghost), press R to rotate, left-click. | You must stand still for **3 s** (the progress bar shows). "Campfire built." 3 wood are consumed and the lighter loses 1 of its 25 uses. A fire model appears with prompts E "Rest by the fire", Q "Cook food & boil water" and F "Add wood". |
| BD-02 Tarp shelter | 4 wood, 2 rope, 1 tarp (from the Base Camp crate). **Needs a medium pack**: about 10.9 kg of materials on top of the 3.7 kg baseline overloads the daypack. | Build *Emergency Tarp Shelter*. | 6 s build. An A-frame tarp appears. "+25 XP First emergency shelter" appears the first time per profile only. The prompts are E "Rest under the tarp" and F "Reinforce (1 rope)". Inside it, `InShelter` = true, wind is cut to 25% and precipitation is blocked. |
| BD-03 Wind wall | 5 wood | Build *Wind Wall*. | 4 s build. Within 8 studs of it, wind is reduced to 40% (`WindMs` drops). Precipitation is **not** blocked. |
| BD-04 Trail marker | 1 wood | Build *Trail Marker* in fog. | 1.5 s build. An orange dot billboard is visible to **all** players through fog and terrain, out to 400 studs. |
| BD-05 Locked / unimplemented | — | Browse the Build Book. | Wind-Protected Fire, Snow Shelter, Rope Anchor, Snow Melter, Signal Fire and Avalanche Shelter show as "Blueprint missing" and can't be placed. |
| BD-06 Invalid: water | Stream at about (−75, 18, 130) | Aim at the water and place a campfire. | "You can't build in water." |
| BD-07 Invalid: steep | — | Place a campfire (max 25°) on the flank where the safe ramp drops into the ravine (X ≈ 130, Z ≈ 550). Then place a tarp (max 18°) on the safe ramp itself, which is about 18.4°. | The ghost turns red. The server says "Too steep (N°, max M°)." Note: the tarp should be refused on the safe ramp and the campfire accepted there. Confirm with design that this is intended. |
| BD-08 Invalid: overlap | An existing campfire | Place a second campfire within about 4.5 studs of it, then next to a camp fire, a tree or a rock. | "Something is already built there." for structures, and "Blocked by <PartName>." for trees, rocks and cabins. Characters never block. |
| BD-09 Invalid: out of range | — | Aim beyond 14 studs. | The client ghost clamps to 13 studs, so you can't place far normally. The server check is covered in E-08. |
| BD-10 Interrupt by moving | — | Start building a tarp and walk away during the 6 s timer. | "Building interrupted." once you move more than 4 studs. **No materials consumed.** The progress bar disappears. |
| BD-11 Interrupt by downed / materials gone | 2 players | P1 starts a tarp. P1 gives away rope during the timer (or P1 gets downed). | Giving away materials during the build gives "Not enough materials." at the end and nothing is built or consumed. Getting downed gives "Building interrupted." |
| BD-12 Busy | — | Try to start a second build during a timer. | "You're already building." |
| BD-13 Tarp wear | Tarp in the blizzard (wind > 15 m/s) | Wait. Then reinforce with rope (F, hold 1.5 s). | Durability drops. At ≤ 25 nearby players get "The tarp is tearing loose in the wind! Reinforce it with rope." At 0: "The tarp shelter collapsed!" and the model is removed. Reinforcing adds 60 durability, or says "holding fine" at ≥ 95. Snow visibly piles on the roof in snowfall. |
| BD-14 Structure cap | (Perf) Build 80+ markers | — | At 80 structures, the oldest non-permanent structure is removed when a new one is built. Camp fires and cabins are never removed. |

### 2.7 Fire

| ID | Setup | Steps | Expected |
|---|---|---|---|
| FR-01 Warmth | Cold (Warmth < 50), next to a lit fire | Stand within about 4 studs. | `NearFire` = true and the HUD shows "by a fire". Warmth recovers fast: a unit test asserts a freezing player recovers in under a minute. A player campfire gives up to 28 °C of heat within 16 studs. Camp fires give 30 °C within 20 studs. Cold warnings are suppressed near the fire. |
| FR-02 Drying | Soaked (Wetness 1) | Stand about 4 studs from a fire, out of the rain. | Wetness falls to 0 in under a minute. In the rain, drying is 4× slower. |
| FR-03 Rest | — | Press **E** "Rest by the fire". | You sit (`Resting` = true, `Exertion` = rest). Fatigue recovers at 1.5/s, or 3/s inside a camp radius (45). Moving faster than 3 studs/s ends the rest. At a **camp** fire, resting heals a *Sprained Ankle* in 30 s, an *Injured Hand* in 30 s and a *Broken Leg* in 75 s. |
| FR-04 Cook & boil | Canned stew in the pack, untreated water in the bottle | Press **Q** (hold 2 s). | "N food heated, M bottle(s) boiled." Canned stew becomes *hot stew*. All water becomes treated and hot (hot for 150 s; the thermos stays hot indefinitely). Drinking hot water gives +12 warmth to every region. With nothing to cook: "Nothing to cook or boil." |
| FR-05 Melt snow at Ridge Camp | Empty bottle and thermos. It is **snowing** at Ridge Camp (Light Snow or colder). | Press Q at the Ridge Camp fire (0, 150, 768). | "… X.X L of snow melted." Containers fill with treated, hot water. The camp fire is permanent, so no fuel is used. At a player campfire, melting costs 15 fuel per litre. **Note:** melting depends on air temperature (falling snow), not snow on the ground. At Ridge Camp in Clear (about 3 °C) or Cloudy (about 1.2 °C) weather you get "Nothing to cook or boil." Confirm with design that this is intended. |
| FR-06 Add wood | Lit player campfire, wood in the pack | Press **F** "Add wood". | +90 s of fuel per wood, up to 600. Near the cap: "The fire is already roaring." With no wood: "You have no wood." |
| FR-07 Burnout | A new campfire (180 s of fuel) | Time it until it goes out (a) in calm Clear weather in the forest and (b) at Ridge Camp in a blizzard, outside any shelter. | Burn rate = 1 + wind/20 + 1.5 × precipitation (if not under a shelter). (a) about 165 s. (b) wind 20 and precipitation 1 give a 3.5× rate, so **about 50 s**. On burnout the flames, light and prompts disappear and the embers go grey with faint smoke. The model is removed after 90 s. Warmth and `NearFire` stop immediately. |
| FR-08 Lighter uses | — | Build campfires until the lighter runs out. | After 25 uses: "Lighter is used up." and the lighter leaves the pack. Campfire then says "You need a lighter." |

### 2.8 Weather

| ID | Setup | Steps | Expected |
|---|---|---|---|
| WX-01 Gradual transitions | Fresh server | Watch `WorldState` for 10+ minutes. | Starts Clear and holds for 150–300 s. Every change is to a **neighbour state only** (Clear↔Cloudy↔{Windy, Fog, LightPrecip}…). `WeatherBlend` climbs smoothly from 0 to 1 over **75 s**, and `WindMs`, `Fog`, `Cloud` and `Precipitation` ease rather than snap. Sky, fog and particles on the client follow the change. It never jumps straight from Clear to Storm. |
| WX-02 Forced storm after Ridge Camp logbook | Any weather | Be the first player to sign the Ridge Camp logbook (CP-02). Start a stopwatch. | 60–120 s later everyone gets "The wind is picking up. Dark clouds are pouring over the ridge." After a 20 s warning hold, the weather walks the shortest path to Storm one state at a time, **40 s blend per step**. From Clear that is Cloudy → Light → Heavy → Storm, about 3 minutes in total. Each severe state (Heavy, Storm) sends "SEVERE WEATHER APPROACHING: HEAVY SNOW / BLIZZARD", named by each player's own elevation. This happens only **once per server**. |
| WX-03 Snowfall at snowline | Weather is Clear, Cloudy or Windy | The first player reaches Y ≥ 135 (snow slope at about Z 650, or safe ramp at about Z 675). | Within about 2 s (poll interval) plus 5 s of warning, the weather starts moving to LightPrecip. Players at the snowline see *Light Snow*. Players at Base Camp see *Light Rain* (about 7 °C). Only once per server. If the weather was already precipitating, nothing is forced. |
| WX-04 Rain vs snow by altitude | During Light or Heavy precipitation | Compare `Weather`/`TempC` at Base Camp, the cliff top and Ridge Camp. | Rain where it is ≥ 1 °C and snow below. Light precipitation: about 7 °C at Base Camp (rain), about 1.2 °C at the cliff base (rain), about −0.8 °C at Ridge Camp (snow). **Note:** in a full Storm (−10 °C offset) Base Camp is −1 °C, so the storm is a *Blizzard* everywhere in the slice. "Thunderstorm" never appears in the slice. Confirm with design that this is intended. |
| WX-05 Shelter hides precipitation | In snow or rain | Walk into the cabin or under a tarp. | `InShelter` = true, the HUD shows "sheltered", client particles hide, and wetness stops rising. |

### 2.9 Checkpoints

| ID | Setup | Steps | Expected |
|---|---|---|---|
| CP-01 Base Camp logbook | Fresh | Press **E** (hold 1 s) at (−12, 0, −14). | "You signed the Base Camp logbook. You'll return here if evacuated." No XP, because Base Camp is the starting checkpoint. |
| CP-02 Ridge Camp logbook | Arrive at Ridge Camp | Sign at (14, 150, 756). | `Checkpoint` = 2 and `CheckpointName` = "Ridge Camp". "+150 XP Reached Ridge Camp" for you, and "<name> reached Ridge Camp." for everyone. `totals.checkpoints` +1. The storm is scheduled (WX-02). Signing again gives the plain "You signed…" message with no XP. |
| CP-03 Respawn at camp | Checkpoint 2 | Get evacuated (RS-06), or fall below Y −30 (for example into the void off the map edge). | You respawn or are recovered within about 4 s, ±4 studs of (0, 150, 786). Below −30 you get "You were recovered from the ravine, exhausted." and +20 fatigue. With **StreamingEnabled** the character must not fall through terrain that hasn't streamed in yet at Ridge Camp. |
| CP-04 Lower camp re-sign | Checkpoint 2 | Go back down and sign at Base Camp. | The message is just "You signed the Base Camp logbook.", without the "You'll return here" promise. The checkpoint stays at 2: signing a lower camp never moves your respawn down. |

### 2.10 Rockfall

| ID | Setup | Steps | Expected |
|---|---|---|---|
| RF-01 Natural trigger | Clear weather | Stand on the safe ramp inside EastGully (for example (150, 100, 600)) and wait. | A check runs every 5 s with a 7% chance × the weather `disasterMult` (Clear 1, Light 1.4, Heavy 2, Storm 3), so expect a trigger within about a minute in Clear. Cooldown is 75 s between events. Nothing triggers while the zone is empty. |
| RF-02 Telegraph | When it triggers | Watch and listen. | **T−5 s:** players within 140 studs get "ROCKS ARE LOOSENING ABOVE YOU", a light camera shake for 5 s, a rumble sound, dust plumes at the three release points on the ridge at X 182, and harmless pebbles trickling west. **T+0:** 3 to 5 boulders (3.5–6 studs) roll −X across the ramp, simulated by the server. **T+10 s:** the boulders and dust disappear completely. No invisible boulders are left as obstacles on the ramp; walk the boulder paths afterwards to check. Survivors in range get `disastersSurvived` +1 in the summary. |
| RF-03 Injuries | Stand in a boulder's path | Get hit. | Only boulders moving faster than 18 studs/s hurt. Damage is 12–45 × size/5 (up to about 54). 40% chance of *Bleeding* and 25% chance of *Injured Hand*. Camera shake. At most one hit per boulder per 1.5 s. A heavy hit at low HP **downs** you. A boulder resting still does no damage. |
| RF-04 Forced trigger | Studio | In the server command bar: `require(game.ServerScriptService.Server.Services.DisasterService).forceRockfall()` | A rockfall sequence starts in EastGully. **If nothing happens**, the command bar probably got its own copy of the module. File a request for a Studio-only debug hook (a BindableFunction or similar), and use RF-01 in the meantime. |
| RF-05 Dodge | — | Run off the ramp line (east, against the ridge) during the warning. | The boulders miss you. The telegraph gives enough time to react (5 s). |

### 2.11 Rescue

All rescue cases need **2+ players** (Test → Clients and Servers). Quick way to get downed: set Health to 5 from the server command bar, then take any damage, for example a 20+ stud drop off the rest ledge.

| ID | Setup | Steps | Expected |
|---|---|---|---|
| RS-01 Downed at 0 HP | P2 with low HP | P2 takes lethal damage (fall, rockfall, cold). | P2 is **not killed**: Health stays at 1 and `Downed` = true. P2 sees a red overlay "DOWNED m:ss" with a countdown from **2:00**, "Crawl toward a fire…" and a "Give up (evacuate)" button. P2 can crawl at 2 studs/s and can't jump. Everyone sees "P2 is down (<cause>)! Revive or carry them to a fire." and a red "DOWNED m:ss" billboard over P2, visible to 500 studs. The P2 entry in the teammate list reads DOWNED. P2 can't see its own Revive/Carry prompts. |
| RS-02 Bleed-out timer | P2 downed | Watch `BleedOut`. | It counts down 1/s. It runs 1.5× faster with *Bleeding*, 0.5× while carried and 0.5× near a fire (these multiply). Further damage while downed takes 25% of the damage off the timer. |
| RS-03 Revive without kit | P1 has no first aid kit | P1 holds **E** "Revive" on P2 for **4 s**. | P2 gets up with **30 HP**: "P1 got you back on your feet." P1 gets "+100 XP Revived P2", and everyone sees "P1 revived P2." P1's `teammatesRescued` +1. The billboard and prompts disappear. |
| RS-04 Revive with kit | P1 has a first aid kit | Revive. | One kit is consumed. P2 gets up with **60 HP** and *Bleeding* removed: "…with a first aid kit." |
| RS-05 Carry / set down | P2 downed | P1 holds **F** "Carry" (1 s). Walk 50 studs to a fire. Press **X**. | P2 is draped across P1's shoulders (fireman's carry). P1 status line: "Carrying P2 · X to set down". P2 sees "Being carried by P1". P1 moves at 0.55× speed, can't jump or climb, and drains stamina at 3.5/s. P2's bleed-out runs at half speed. X sets P2 down about 2.5 studs to P1's side, still downed and able to crawl. Being carried causes no fall damage to P2. Note: per the code, carrying continues at 0 stamina without an auto-drop. Confirm with design. |
| RS-06 Evacuation | P2 downed | Let the timer run out, **or** P2 holds "Give up (evacuate)" for 1.5 s (a short click must not fire). | P2 respawns at the last signed camp. Everyone sees "P2 was evacuated. Their pack is still on the mountain." At the spot where P2 lay, a big bundle "P2's pack" holds **all pack contents**. P2 keeps worn clothes and the backpack tier, and gets a fresh 500 ml treated bottle and an energy bar. Stats are reset to at least hunger 60, thirst 60 and warmth 70. Injuries and wetness are cleared, stamina is 40 and fatigue +25. |
| RS-07 Recover pack | After RS-06 | P1 (and separately P2) holds E (1.5 s) on "P2's pack". | Items move into the picker's pack up to the slot and weight limits. Messages: "You took what you could carry." for a partial pickup, "Your pack is full or too heavy." when nothing fits, and when emptied the bundle disappears with "You recovered P2's gear." **Check:** P2 picking up their own pack must not say "You recovered P2's gear". This was a display-name vs user-name mix-up, now fixed; retest with an account whose DisplayName ≠ Name. The bundle sits on the ground and doesn't float above where P2's body was. The pack despawns after 30 minutes. |
| RS-08 Downed carrier | P1 carrying P2 | P1 gets downed (low HP + fall). | P2 is released (dropped beside P1), and both are downed. |
| RS-09 Climb while carrying | P1 carrying | P1 presses C at the cliff. | Refused. If P1 somehow starts climbing, the carry is released within 1 s. |
| RS-10 Treat a downed teammate | P2 downed and *Bleeding*, P1 has a bandage | P1: pack → bandage → Treat P2. | Bleeding is removed and the bleed-out rate drops from 1.5/s to 1/s. P2 stays **downed**: treatment never revives. |
| RS-11 Hypothermia knock-out | SV-05 | Stay at Critical warmth for 20 s. | Downed with cause "hypothermia". A revive resets the critical-cold timer. |

### 2.12 Section end summary

| ID | Setup | Steps | Expected |
|---|---|---|---|
| SE-01 | Any route to the Ridge Col | Walk within 22 studs of (0, 260, 1070) (cairn and flag). | Within 1 s: "+300 XP Reached the Ridge Col", plus "<name> reached the Ridge Col!" for everyone. A summary appears showing name, max elevation (m), distance (m, at 0.28 m/stud, ignoring teleports > 40 studs/tick), time, highest checkpoint, weather survived (severe states lived through while exposed), disasters survived, teammates rescued, items consumed, injuries and resources collected. `totals.sectionsCompleted` +1. It triggers only once per expedition, and not while downed. |
| SE-02 | Downed inside the radius | Get revived inside the radius. | The summary appears after the revive, not while downed. |

### 2.13 Saving

| ID | Setup | Steps | Expected |
|---|---|---|---|
| DS-01 API access off | Game Settings → Security → *Enable Studio Access to API Services* **off** | Play. | Output: `[DataService] Studio has no DataStore access; running in-memory.` (or "DataStore unavailable…"). You play normally with a default profile. No "couldn't be loaded" warning. Nothing persists after Stop. |
| DS-02 API access on: progression persists | API access **on** (use a test place, never the live universe) | Play. Sign Ridge Camp (+150 XP). At the outfitter wear the insulated parka and switch to the medium pack. Stop. Play again. | `XP` = 150 (Player attribute) and `Rank` = "Beginner Mountaineer". You spawn wearing the parka with the medium pack, because the saved loadout applies. **Pack contents, injuries and the checkpoint reset**: an expedition is per session. `totals.expeditions` increments each new session. |
| DS-03 Rank up | API on | Gain 500+ XP across sessions (checkpoint 150 + col 300 + first shelter 25 + revive 100). | "Rank up: Hiker" on crossing 500, and it persists. |
| DS-04 Autosave / shutdown | API on | Gain XP, then wait 2+ minutes (autosave every 120 s). Then end the session by closing Studio play. | No errors in Output. Data from both the autosave and the BindToClose save is there on the next run. Close waits up to 25 s for pending saves. |
| DS-05 Session lock | Published test place, two servers | Join server A, leave and immediately join server B. | Server B may log `[DataService] <name> is locked by another server (attempt n)` and retry every 4 s, up to 6 tries. Once A's leave-save releases the lock, B loads the **latest** data. If the lock never clears: "Your saved progress couldn't be loaded…" and the session is read-only. Nothing is overwritten. |
| DS-06 Quick rejoin, same server | API on, published test place | Leave and rejoin the same server within a few seconds. | The new session waits (up to 30 s) for the previous session's final save before loading. XP gained just before leaving is present and there is no "locked by another server" loop. |
| DS-07 Leave during load | API on, slow DataStore (e.g. the first join of the day) | Leave within 1 s of joining, then join a different server. | No 10-minute lockout: the lock taken by the abandoned load is released. |
| DS-08 Corrupt / legacy data | API on, write junk to key `u_<userId>` in store `MountainProfiles_v1` (e.g. with a DataStore editor plugin) | Play. | The profile is repaired: unknown items and blueprints are dropped and numbers are clamped. No crash. |

---

## 3. Multiplayer matrix

Use **Test → Clients and Servers**, choose the player count and press Start. Each client gets its own window, and the Server window has the server command bar. Re-run the solo checks in each configuration and add the ones below. Everything server-built must look identical on every client: gear, structures, boulders, downed markers, trail markers and pings.

| Check | Solo | 2 players | 4 players | 6 players |
|---|---|---|---|---|
| Boot: no errors, HUD on every client, each player has its own loadout | ✔ | ✔ | ✔ | ✔ |
| Spawn: all spawn at Base Camp without stacking or getting stuck | ✔ | ✔ | ✔ | ✔ |
| Teammate list (top-left) shows the others with HP and DOWNED / injured / freezing | — | ✔ | ✔ | ✔ (list fits 5 names) |
| Give / Treat buttons list only teammates within 10 studs | — | ✔ | ✔ (crowd 3 players together) | ✔ |
| Ping (G): marker and name visible to all within 600 studs. Spam is rate limited (0.5/s, burst 3) | ✔ (self) | ✔ | ✔ | ✔ (all 6 ping together) |
| Equipment visuals replicate, including wetness and snow on other players' packs | — | ✔ | ✔ | ✔ |
| Supply crate / outfitter allowances are **per player** (P2's taking doesn't reduce P1's) | — | ✔ | ✔ | ✔ |
| Weather is identical for all players (same `WorldState`), but the *name* depends on altitude (rain below, snow above) | ✔ | ✔ (split P1 base, P2 ridge) | ✔ | ✔ |
| Snowline / storm director fires **once per server**, triggered by the *first* player only | ✔ | ✔ | ✔ | ✔ |
| Rescue: revive, carry, set down, evacuate, recover pack | — | ✔ (full RS suite) | ✔ (two downed at once, two rescuers on one target) | ✔ |
| Building near others: players never block placement, structures block each other | — | ✔ | ✔ | ✔ |
| Rockfall with several players in the gully: each can be hit, the telegraph reaches everyone within 140 studs | ✔ | ✔ | ✔ | ✔ |
| Checkpoint: each player signs separately. "X reached Ridge Camp" broadcast once per player | ✔ | ✔ | ✔ | ✔ |
| Section end: per-player summary, broadcast to all | ✔ | ✔ | ✔ | ✔ |
| Performance (section 5): server heartbeat, network, memory | baseline | — | ✔ | **target config** |

At 4 and 6 players, also run one full **15–25 minute expedition** with everyone: base → trail → split up (two players on the cliff, the rest on the safe ramp) → Ridge Camp → storm → col. Watch for desyncs, stuck prompts, errors and frame drops.

---

## 4. Edge cases and exploit tests

### 4.1 Gameplay edge cases

| ID | Case | Steps | Expected |
|---|---|---|---|
| E-01 | **Disconnect while carrying** | P1 carries downed P2. Kick P1 (`game.Players.P1:Kick()`) or close P1's window. | P2 is released at P1's last position, still downed. Their bleed-out runs at full speed again. Their Revive/Carry prompts still work for others. No orphaned weld, no massless/PlatformStand left on P2, and P2's network ownership returns to P2 (P2 can crawl). |
| E-02 | **Disconnect while being carried** | P1 carries P2. Kick P2. | P1's `Carrying` attribute clears and P1 is back to normal speed, jumping and climbing. No leftover parts on P1. |
| E-03 | **Disconnect during building** | P1 starts a 6 s tarp build. Kick P1 at 3 s. | Nothing is built and no errors appear. On rejoin within 10 minutes (same server) P1 still has the materials and isn't "already building". |
| E-04 | **Downed with inventory open** | Open the pack, then get downed. | The pack stays usable visually, but Use / Give / Treat / Wear return "You're incapacitated." **Drop is allowed** (you can leave items for teammates). The UI doesn't break and shows nothing stale after a revive. |
| E-05 | **Two players pick up the same item** | P1 drops a stack. P1 and P2 both hold E on the bundle and release at the same moment. Repeat with an evacuated pack (1.5 s hold). | Each item is granted **once** in total. One player gets it, or a partial pickup is split between them. The total count across both packs equals what was dropped (check with the pack panels). The model disappears once empty. No duplication. |
| E-06 | **Two players build in the same spot** | P1 and P2 both start a campfire on the same spot (both pass the first validation). | Whoever finishes first builds. The other is refused at the end with "Something is already built there." and **keeps their materials**. |
| E-07 | **Rejoin after evacuation** | P2 is evacuated (pack left on the mountain). P2 leaves and rejoins the **same server** within 10 minutes. | "Welcome back. Your expedition was waiting for you." P2 keeps the post-evacuation state: checkpoint, starter bottle and bar, stats and the `outfitterTaken` / `supplyTaken` allowances (it does **not** get a fresh loadout or new crate allowance). The dropped pack is still on the mountain and not duplicated. In Studio a local server may not let you re-add a player after start. If not, use a published test place and rejoin through the server list or a friend's join. |
| E-08 | **Rejoin after 10+ minutes / new server** | Leave for > 600 s, or join a different server. | A fresh expedition with a new loadout from the saved profile. Progression is kept (when saving is on). |
| E-09 | **Reach a checkpoint during a disaster** | Start a storm or rockfall. Sign the Ridge Camp logbook mid-storm, and sign while another player's rockfall is active. | Signing works normally (XP, broadcast). Rockfall in progress isn't affected. The storm scheduler doesn't schedule a second storm. |
| E-10 | **Downed while climbing / during mantle** | Get hit by damage while on the wall. | The climb stops, the client releases the wall and you fall downed. No floating in place. |
| E-11 | **Climbing while server says stop** | Drain stamina while hanging. | The client lets go immediately on `ClimbForceStop`. No "ghost climbing" where the client is still attached and the server says not climbing. |
| E-12 | **Reset character** | Try Esc → Reset. If the button is somehow available, run `game.Players.P1.Character.Humanoid.Health = 0` in the server command bar while downed. | The reset button should be disabled. If a death does happen, the player respawns (at the last camp if checkpoint ≥ 2) and the downed state clears. **Known risk:** that path keeps the full pack and skips evacuation. File it if reachable without the command bar. |
| E-13 | **Fall off the world** | Walk off the map edge or into the ravine and keep falling below Y −30. | Recovered to the checkpoint after about 3 s. No infinite falling. |
| E-14 | **Respawn during weather and streaming** | Evacuate to Ridge Camp while it is a blizzard, on a slow connection. | You don't fall through terrain that hasn't streamed in. HUD weather updates immediately. |
| E-15 | **Being carried into fire / revived while carried** | P1 carries P2. P3 revives P2 while carried. | The carry is released and P2 stands up beside P1. |
| E-16 | **Give to a downed player at the moment they are evacuated** | P1 gives P2 an item at the same moment P2's timer expires. | The item ends up either in P2's dropped pack or in P2's new pack, never both. |

### 4.2 Exploit and robustness tests (remote spam)

Run these from a **client window's command bar**. In *Clients and Servers*, select a client window; its command bar runs as that client, so `FireServer` works. Watch the **server** Output.

Expected for every rejected call: the server ignores the request. A `RemoteFunction` returns `false, "Request rejected."` (or a handler message), the server never errors, other players are unaffected, and the server logs `[RemoteGuard] <name> rejected on <remote>: <reason> (total N)` on the 1st, 26th, 51st… rejection. There is no automatic kick, because `SUSPICION_KICK_THRESHOLD = 0`.

```lua
local R = game.ReplicatedStorage.Remotes
local nan, inf = 0/0, math.huge
```

| ID | Attack | Command (client command bar) | Expected |
|---|---|---|---|
| X-01 | NaN / inf vectors | `R.Ping:FireServer(Vector3.new(nan,0,0))`, `R.Ping:FireServer(Vector3.new(inf,0,0))`, `R.ClimbStart:FireServer(Vector3.new(nan,0,1))` | Rejected (schema: finite and magnitude-limited). |
| X-02 | Huge numbers | `R.Ping:FireServer(Vector3.new(1e6,0,0))` (> 20000), `R.ClimbStart:FireServer(Vector3.new(0,0,50))` (magnitude > 1.5), `R.Inventory:InvokeServer("Drop", "1", 2^60)` | Rejected. A Drop with a valid huge integer (≤ 2^53) is clamped to the stack size. |
| X-03 | Wrong types / arity | `R.Inventory:InvokeServer({}, {}, {})`, `R.SetSprint:FireServer("yes")`, `R.Inventory:InvokeServer("Use", "1", nil, "extra")`, `R.Outfit:InvokeServer(string.rep("a", 10000))`, `R.Build:InvokeServer("campfire", Vector3.new())` | Rejected: bad argument, too many arguments, or string too long. |
| X-04 | Invalid enum / quantity | `R.Inventory:InvokeServer("Dupe", "1")`, `R.Inventory:InvokeServer("Drop", "1", 0)`, `R.Inventory:InvokeServer("Drop", "1", 1.5)`, `R.Inventory:InvokeServer("Drop", "1", -5)` | Rejected by schema. |
| X-05 | Forged stack uids | Inspect a stack uid (they are small integers such as `"3"`). Call `R.Inventory:InvokeServer("Use", "99999")`, `("Give", "99999", <otherUserId>)`, `("Drop", "abc")`. Try another player's uid. | "You don't have that." Uids are per-inventory, so another player's uid can only ever refer to your own stack. No crash and no item creation. |
| X-06 | Give / Treat abuse | `R.Inventory:InvokeServer("Give", uid, <yourOwnUserId>)`, `("Give", uid, 1)` (non-existent user), `("Give", uid, <far player>)`, `("Treat", uid_of_energy_bar, <mate>)` | "No one to give that to." / "Get closer…" / "That can't be used on someone else." Nothing moves. |
| X-07 | Supply / outfitter from afar | From 50+ studs away: `R.Supply:InvokeServer("BaseCamp", "first_aid_kit")`, `R.Outfit:InvokeServer("pack_expedition")`, `R.Supply:InvokeServer("RidgeCamp", "tarp")` (not in that crate), `R.Outfit:InvokeServer("hot_stew")` (not stocked) | "You need to be at that supply crate." / "You need to be at the outfitter." / "Not in this crate." / "Not available." Allowances aren't consumed. |
| X-08 | Build from 500 studs | `local p = game.Players.LocalPlayer.Character.HumanoidRootPart.Position` then `R.Build:InvokeServer("campfire", CFrame.new(p + Vector3.new(0,0,500)))` | "Too far away." (server range 14). Also try `CFrame.new(nan,0,0)` and `CFrame.new(1e6,0,0)`, which are rejected by schema. Try `R.Build:InvokeServer("signal_fire", CFrame.new(p))`, which gives "You don't know how to build that yet." Try a valid recipe without materials, which gives "Not enough materials." |
| X-09 | Build rotation abuse | `R.Build:InvokeServer("wind_wall", CFrame.new(p + Vector3.new(3,0,0)) * CFrame.Angles(math.pi/2, 0, 0))` | Only yaw is kept: the structure is upright, never on its side. |
| X-10 | Rate-limit spam | `for i=1,500 do R.SetSprint:FireServer(i%2==0) end`, `for i=1,200 do R.Ping:FireServer(p) end`, `for i=1,100 do task.spawn(function() R.Inventory:InvokeServer("Use", "1") end) end` | Only the burst plus the sustained rate gets through (SetSprint 12 + 8/s, Ping 3 + 0.5/s, Inventory 10 + 6/s). Excess calls are dropped and logged every 25 rejections. Other players see at most 3 pings. Server heartbeat doesn't dip noticeably. |
| X-11 | ProximityPrompts from range | In the client command bar, widen every prompt locally: `for _,p in workspace:GetDescendants() do if p:IsA("ProximityPrompt") then p.MaxActivationDistance = 1000 end end`. Then trigger the Base Camp supply crate, a wood source, the Ridge Camp logbook and a downed teammate's Revive from 100+ studs. | The server re-checks distance against its own `MaxActivationDistance + 4`, so **nothing happens**: no panel opens, no wood is given, no checkpoint or revive. The engine may also refuse the trigger on its own. Either way, no effect is a pass. |
| X-12 | Climb hacks | Without facing a wall: `R.ClimbStart:FireServer(Vector3.new(0,0,1))`. On ice without an axe: same, while facing the ice wall. Fly up while `Climbing` (e.g. teleport the client root up by 30 studs). | "Nothing to climb here." / "Ice. You need to hold an ice axe…". A climb with an implausible vertical speed is force-stopped by the server, and you then fall with normal fall damage. |
| X-13 | Downed-state remotes | Not downed: `R.GiveUp:FireServer()`. Not carrying: `R.DropCarried:FireServer()`. While carried: `R.StopRest:FireServer()`. | Ignored. |
| X-14 | Jump stamina dodge | Jump repeatedly while blocking `ReportJump` (e.g. disconnect the MovementController hook). | Known limitation: the jump stamina cost is client-reported. Server-side `JumpHeight` = 0 below 9 stamina still applies. Record the result in the bug report. |
| X-15 | Snapshot spam | `for i=1,50 do R.GetSnapshot:InvokeServer() end` | Limited to 4 + 2/s. Returns a copy: mutating the returned table on the client changes nothing on the server. |

---

## 5. Performance checklist

### 5.1 Targets

| Metric | Target | Where to read it |
|---|---|---|
| **Server heartbeat** | **≥ 55 fps sustained at 6 players** during the storm + rockfall + 6 fires + 6 tarps scenario. No spikes > 50 ms. | Developer Console (F9) → *Server* → **Server Stats** / *Scripts*. In Studio, the Server window → View → Stats → Performance. |
| **Client FPS, low-end phone** | ≥ 30 fps at Base Camp (densest trees) and in a blizzard at Ridge Camp, on a low-end device (for example a 3 GB RAM Android, or iPhone 8 / SE2 class). | Ctrl+Shift+F5 / Developer Console *Client*, or the device's own overlay. |
| **Client FPS, desktop** | ≥ 60 fps | Same. |
| **Client memory, mobile** | Total < about 1,000 MB. LuaHeap stable over a 20-minute run (no steady growth). | Developer Console → **Memory** (*PlaceMemory*, *LuaHeap*, *Instances*, *PhysicsParts*, *GraphicsTexture*). |
| **Network** | Idle player: near-zero attribute traffic (publish thresholds). Steady state < about 30 KB/s received per client at 6 players. No remote fired more than a few times per second per player. | Developer Console → **Network** (Data Send/Receive kbps), or Studio View → Stats → Network. |
| **Part counts** | Generated map BaseParts: record a baseline with the command-bar counter, and treat > 10% growth from one build to the next as a regression. Gear per character: aim ≤ about 60 parts with the full kit. Structures are capped at 80, boulder pool at 10. `GroundItems` should return to 0 after despawns. | Command-bar count; Explorer folders `workspace.Structures`, `workspace.GroundItems`, `workspace.DisasterEffects`, `<Character>.Gear`. |

### 5.2 Tools

* **MicroProfiler** (Ctrl+F6 on the client. On the server in Studio, use the Server window's MicroProfiler, or Developer Console → MicroProfiler on a live server). Pause on a spike and look at the `Heartbeat` / `RunService` event bars and `physicsStepped`. All server services run under one Script ("Server"), so add `debug.profilebegin("SurvivalTick")` … `debug.profileend()` labels in the hot loops before a perf pass. That's a dev task; until then the bars are unlabelled.
* **Developer Console (F9):**
  * **Memory:** Instances and PhysicsParts should be flat over time, and LuaHeap shouldn't climb. Compare before and after 10 builds, 10 rockfalls, 5 evacuations and 50 drops/pickups.
  * **Network:** compare idle against moving against storm. Look for runaway attribute replication.
  * **Scripts:** Activity % and Rate per script. The server "Server" script should stay low single-digit % at 6 players. On the client, check the HUD and controllers.
  * **Log:** zero errors. `[RemoteGuard] … rejected` lines should appear only during exploit tests.
* **Studio Script Performance** window (View → Script Performance) during the 6-player test.

### 5.3 What to look for, system by system

| System | Cost driver | Watch for |
|---|---|---|
| SurvivalService | One Heartbeat accumulator, a 5 Hz tick per player. Each tick does one ground raycast, a WaterVolume scan, `BuildingService.environmentAt` (loops over every structure, up to 80) and about 35 attribute publishes with change thresholds. | Tick cost grows with players × structures. At 6 players and 80 structures, confirm it stays < 1 ms per tick. Attributes for idle players shouldn't change. `ElevationM` uses a 5 m step and `Wetness` a 0.02 step. |
| WeatherService | Heartbeat every frame plus 9 `WorldState` attributes published at 2 Hz. | `WindDirection` changes every publish, so it always replicates. That should be small but constant. Client WeatherController: one emitter box above the camera. Check particle count and fill rate in a blizzard on mobile. |
| BuildingService | 1 Hz fuel, wear and roof-snow simulation. | Roof snow transparency writes replicate every second while it is snowing. Check traffic with 6+ tarps. Extinguished fires are removed after 90 s. |
| EquipmentService | Gear is rebuilt (destroyed and recreated) when the visual signature changes. Wet recolour happens in 10 buckets. Snow cap runs at 1 Hz. | Rebuilds should happen only on gear, pack or held changes, or wood thresholds (1/3/6), not on every InventorySync. Look for bursts of instance creation in MicroProfiler while gathering wood or eating. |
| DisasterService | Server-owned boulder physics (3–5 balls), dust emitters, pebbles. | A physics spike at release. Afterwards the `DisasterEffects` folder must empty and pebbles self-destroy after 8 s. Boulders are pooled (≤ 10) and none should remain in `workspace` after T+10 s. |
| ResourceService | Ground bundles from drops and evacuations. | Drop is allowed at 6/s, so a player cycling pick-up and drop can create many models that each live 10 minutes. Spam Drop for 1 minute and count `GroundItems` children. |
| RescueService | 1 Hz loop, a billboard per downed player. | Billboards and prompts are destroyed after revive or evacuation (Explorer: no leftover `RevivePromptAttachment`). |
| CampService / ExpeditionService | 1 Hz section-end check, 2 s snowline poll until triggered. | Negligible. Verify the snowline loop ends after the trigger. |
| Client HUD | Refreshes at 10 Hz. The teammate list is rebuilt every second (destroy and create labels). | GC churn on mobile. Check the LuaHeap sawtooth isn't growing. |
| Client climbing / build ghost | 2–3 raycasts per frame while climbing (new RaycastParams each frame). Raycast every RenderStepped while placing. | Frame time on mobile while climbing in a blizzard. |
| World (WorldBuilder) | About 170 trees + 75 rocks + camps, as greybox parts. StreamingEnabled is on. | Map generation time is printed at start. Note it per build. Streaming pop-in of trail markers (400 studs) and downed markers (500 studs). |

### 5.4 Perf scenario script (6 players, about 10 minutes)

1. All 6 spawn and gather wood near base. Record the baseline server heartbeat, part count and client memory.
2. Everyone builds a campfire and a trail marker. Two players build tarps. Record again.
3. Teleport everyone to Ridge Camp. Sign the logbook (the storm comes 60–120 s later).
4. During the blizzard, three players stand in EastGully until a rockfall triggers, and one gets downed and carried.
5. Spam Drop and pick-up from one client for 60 s.
6. Record peak and average server heartbeat, the worst client FPS (phone), Network KB/s and Memory, then compare with the targets in 5.1.

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
<starting state: location (X, Y, Z or landmark), weather, gear, pack contents, checkpoint>

**Steps to reproduce**
1.
2.
3.

**Expected** (quote the doc's Expected column if a test case exists)

**Actual**

**Evidence**
- Output / Developer Console log lines (server and client, copied as text):
- Relevant Player attributes at the time (Stamina, Warmth, Downed, Injuries, Weight, …):
- WorldState attributes (WeatherFrom/To/Blend) if weather related:
- Screenshot / video:
- MicroProfiler dump (perf bugs):

**Notes / suspected cause** (optional; file and line if known)
```

Severity guide:

* **Blocker:** the test plan can't proceed (no client boot, server error on start, can't leave Base Camp).
* **Critical:** progress or data loss, item duplication, a server crash, or an exploit that grants items, XP or teleports.
* **Major:** a core mechanic is wrong (fall damage, rescue, weather, saving).
* **Minor:** wrong numbers or messages, a UI glitch.
* **Cosmetic:** visual only.
