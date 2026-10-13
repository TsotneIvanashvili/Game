# Summit Expedition

A co-op (up to 6 players) polar-mountain expedition survival game for Roblox, written in Luau and
synced with Rojo. Gear up in the equipment tent at Base Camp, then climb through a snow valley,
an icefall of crevasses and rope bridges, an ice wall, a glacier and a knife-edge ridge to the
Summit, managing stamina, food, water, warmth, injuries, a pack with real weight, a day/night
cycle and storms. Teammates revive, carry and treat each other; camps are checkpoints.

Art direction: stylized, bright and chunky (see [docs/ART_DIRECTION.md](docs/ART_DIRECTION.md)).

> **Status: playable build, NOT yet verified in Roblox Studio.**
> Every file compiles with the Luau compiler and passes selene and StyLua; the logic, climate,
> terrain and route have unit tests. Nothing has been confirmed inside the real Roblox engine
> yet, and the game is silent (no sound ids yet). See [docs/ROADMAP.md](docs/ROADMAP.md).

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how everything works (server authority, services,
  remotes, data models, survival math, tag contract for hand-built maps)
- [docs/ROADMAP.md](docs/ROADMAP.md): checkpoint status, vertical-slice checklist, next steps
- [docs/TESTING.md](docs/TESTING.md): automated checks and the manual Studio test plan
- [docs/ART_DIRECTION.md](docs/ART_DIRECTION.md): the stylized look, palette, UI language
- [docs/ASSET_SPECS.md](docs/ASSET_SPECS.md): construction specs for 3D art

## Setup

1. Install [Rokit](https://github.com/rojo-rbx/rokit) (toolchain manager).
2. In this folder run `rokit install`. This installs the pinned rojo 7.4.4, stylua 2.0.2 and
   selene 0.27.1 from `rokit.toml`.
3. Run `rojo serve` (uses `default.project.json`).
4. In Roblox Studio, install the Rojo plugin (7.4.x), open an empty place (delete the template's
   Baseplate and SpawnLocation; the server generates the map), and click **Connect** in the
   Rojo plugin. Alternatively `rojo build -o MountainSurvival.rbxl` and open that file.
5. Publish the place, then **Game Settings -> Security -> Enable Studio Access to API Services**
   so DataStores work in Studio. Without it the game runs with in-memory profiles and says so in
   the output.
6. Set **Max Players to 6** in the place's settings (Game Settings / Creator Dashboard). The code
   does not enforce a player cap.
7. Verify **Workspace.StreamingEnabled = true** in Properties (the project file sets it).

Press Play. The world builds before anyone spawns. The server output shows `[World] ...`, `[Server] 15 services started in ...s` and a one-line `[Report] ...` summary of what was built. To
use a hand-built map instead, put a Model named `Mountain` in Workspace and follow the tag
contract in ARCHITECTURE section 16.

## Controls

| Key | Action |
|---|---|
| W A S D | Move (on a wall: climb up/down/sideways) |
| Shift (hold) | Sprint |
| Space | Jump; jump off the wall while climbing |
| C | Grab / let go of a climbable wall (rock; ice needs a held ice axe) |
| Tab or I | Backpack: worn gear, contents, use / equip / hold / drop / give / treat |
| B | Build Book: campfire, tent, tarp shelter, wind wall, trail marker (R rotate, click place, right-click or Esc cancel) |
| H | Gear toggles: helmet, mask, goggles, headlamp |
| M | Route panel: camps reached and altitude |
| V | First / third person |
| 1-4 | Hotbar quick use (water, food, first aid, ice axe) |
| G | Ping a spot for your team |
| X | Set down a teammate you're carrying |
| E / F / Q | World prompts: gather wood, fill bottles, open crate or outfitter, sleep, rest by the fire, add wood, cook and boil, revive (E), carry (F) |

Stepping into a camp's green ring checks you in there.
When downed, hold the on-screen "Give up" button to evacuate to your last camp (your pack stays
where you fell). Gamepad and touch buttons are bound for climb, sprint, drop and ping.

## Tests

```sh
tests/check.sh   # full check: compile every .luau, selene, stylua --check, unit tests
tests/run.sh     # unit/stress tests only (src/shared Logic + Config)
```

The tests run the pure logic modules in a standalone Luau VM. `tests/harness.luau` fakes the
`script` instance tree and stubs `Vector3`/`Color3`; `tests/compile_check.luau` compiles each
file with the real Luau compiler. Both need **`luaurun`** on your PATH, a ~20-line Rust host built
on [mlua](https://github.com/mlua-rs/mlua) that exposes `__loadfile(path)` and `ROOT`:

```toml
# Cargo.toml
[dependencies]
mlua = { version = "0.10", features = ["luau", "vendored"] }
```

```rust
// src/main.rs  -- usage: luaurun <script.luau> [root]
use mlua::{Lua, Result};
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let src = std::fs::read_to_string(&args[1]).expect("read script");
    let lua = Lua::new();
    let load = lua.create_function(|lua, p: String| {
        let s = std::fs::read_to_string(&p).map_err(mlua::Error::external)?;
        lua.load(s).set_name(p).into_function()
    })?;
    lua.globals().set("__loadfile", load)?;
    lua.globals().set("ROOT", args.get(2).cloned().unwrap_or_else(|| ".".into()))?;
    lua.load(src).set_name(args[1].as_str()).exec()
}
```

Build it with `cargo install --path .`. `selene` and `stylua` come from `rokit install`.
Services and client controllers are not unit tested; they need a Studio play-test.
