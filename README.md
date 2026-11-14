# realm

The next core of Thousand Realms: one repository for the shared game rules,
the Rust servers, the Godot client extension and the tools. The plan and its
phases are in `../plans/rebuild-plan.html`; the live game keeps running from
`hpmmo-client` and `hpmmo-server` until the switch-over (Phase 8).

| Path | What it is |
| --- | --- |
| `crates/realm_sim` | Game rules (fixed 30 Hz step): movement (walk, jump, stairs, slopes, swimming, broom) over a collision world, navigation queries, the castle's moving staircases (a pure function of the tick). Bit-identical on every platform. No Godot types. |
| `crates/realm_proto` | Wire format: bit packing, input batches, snapshots (owner's body lossless, other entities delta-coded), and the control channel (`control`: the join stream kept open for framed, reliable messages both ways). |
| `crates/realm_rules` | Game rules beyond movement: the character sheet (what is saved, sent to its owner and changed by the server), items, looks, and the typed content they read. Grows with each Phase 5 slice. |
| `crates/realm_data` | Content loading, rename map, typed ids and cross-reference checks, content hash. |
| `crates/realm_content` | `import` (old game data -> `content/data` through the rename map), `check`, `art` (copies art from the old client into `game/` with everything it references, renaming paths and the names inside models; fails on any franchise-derived word left) and `scan` (the same check over any text files: scripts moved by hand, catalogues; CI runs it). |
| `crates/realm_simcheck` | Scripted movement on a fixed test world + wire round trips + crowd bandwidth; CI compares its output across platforms. |
| `crates/realm_server` | Map server (one process per map and channel): QUIC join with signed tickets, 30 Hz ECS simulation (players, creatures with sleep and AI levels of detail, bolts), interest grid, prioritized delta snapshots; `keygen`, `serve`, `selfcheck`. Loads one compiled map pack; creatures follow navigation-mesh paths. |
| `crates/realm_worldc` | World compiler: Godot export -> map packs (colliders, terrain, water, moving geometry, navigation mesh baked with rerecast); `check` walks bodies from every spawn point and tests paths. |
| `crates/realm_bots` | Load-test clients over the real join path; each runs to the nearest creature and attacks it. |
| `crates/realm_netclient` | The client's network core without Godot: prediction with exact reconciliation, snapshot store, remote-entity interpolation (`ClientCore`), and the QUIC connection on a background thread (`NetHandle`). |
| `crates/realm_client` | GDExtension the Godot client loads: `RealmSession` (joins, steps the 30 Hz prediction, reports own body, others, stats and the map as meshes). |
| `crates/realm_netem` | UDP proxy that adds delay, jitter and loss in both directions. |
| `crates/realm_netcheck` | One scripted player through `ClientCore`; fails on any correction (Phase 4 exit). |
| `game/` | The new Godot client (Mobile renderer). Players are the real hero (`scripts/view/hero_view.gd`), creatures their real models (`creature_view.gd`, from `content/data/creature_views.json`; a boss wears its authored boss body sized by `boss_overrides`), Dark Shards and training dummies their own views (`stone_view.gd`: idle glow, waves, shatter, fall-in; `dummy_view.gd`); the map's boss and stone notices show on the notice band; the old game's approved windows (Arcane frame, Turkish by default: `scripts/ui`, `locale/tr.po`) read the sheet through `scripts/view/player_sheet.gd`, the inventory (I) first; the map is still grey collision geometry until the scenes stream in (Phase 6). Art is in LFS. |
| `crates/realm_perfgate` | Checks a reference-machine performance report against `perf/budgets.toml`. |
| `world/maps/*.realmmap` | Compiled map packs (zstd + postcard), one per map. |
| `tools/world_export` | Godot script that exports the old game's collision world for `realm_worldc`. |
| `content/rename_map.toml` | Old game id -> new id (no franchise-derived id reaches the new core). |
| `content/data/` | The game's content (12 JSON files, imported 2026-11-13). Keys starting with `_` are author notes. |
| `perf/budgets.toml` | Client budgets on the reference machine (low preset). |
| `tools/gdext_smoke` | Smallest Godot project that loads `realm_client`. |

## Commands

```bash
cargo build --workspace                              # everything
cargo run -p realm_server -- selfcheck               # QUIC loopback: TLS, stream, datagrams
cargo run -p realm_perfgate -- perf/budgets.toml report.json [--report-only]
cargo run --release -p realm_simcheck [-- --trace stairs | --bench]   # movement fingerprint / cost
cargo run --release -p realm_server -- keygen keys            # dev ticket key + TLS cert (keys/ is gitignored)
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --dev-spawn-near-packs   # or --dev-spawn-near troll_forest | grak | stone_dark | training_dummy
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --characters build/characters   # characters persist (JSON per character); Ctrl+C saves all
cargo run --release -p realm_bots -- --count 500 --seconds 120 --ramp 50   # each bot learns --skill shockwave=3 and opens with it
cargo run -p realm_content -- check content/rename_map.toml content/data
cargo run --release -p realm_worldc -- check world/maps content/data
cargo run --release -p realm_netem -- --listen 127.0.0.1:7800 --server 127.0.0.1:7777 --delay-ms 100 --loss 0.02
cargo run --release -p realm_netcheck -- --server 127.0.0.1:7800 --map castle_interior --seconds 60
```

netcheck also runs the control channel: a look request and item requests
(equip, unequip, wrong slot, potion at full health, bag moves, selling,
buying away from a shop, refining without material, a stale request). On a
new character it runs the refusals; on the prepared character it runs the paid
paths (potion, refine +2, imbue, reweave, buying at a hearth):

```bash
python tools/fixtures/make_prepared_character.py build/characters 900002
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --characters build/characters
cargo run --release -p realm_netcheck -- --server 127.0.0.1:7777 --character 900002 --seconds 6
```

Crowd control runs on the server: a spell's stun, freeze, slow, throw,
weakening, burn and bleed, and the gear's stun/slow/burn procs, land on the
creature it hit and reach every client as the entity's status byte
(`STATUS_*` in realm_proto); the server's stats line counts holds, procs and
burn/bleed ticks.

Creatures think on the server (`sim/brain.rs`): aggressive packs attack a
player they see, reactive ones answer a blow; the last hitter is the target and
pack mates join; the leash runs from the pack's anchor; attacks wind up and
land on a release tick; every Nth attack is a telegraphed ability (a
`telegraph` combat event carries its shape and release tick), a target out of
reach can draw a thrown one, casters throw bolts. Abilities stun, throw, web,
poison and despair players (`sim/afflict.rs`); the holds travel in the owner's
snapshot as a `Restraint` in the player's own input ticks, so prediction
replays them exactly; a life counter in the same snapshot marks deaths and
respawns. The client draws a telegraph as the old game's projected ground mark
filling toward its release tick against `RealmSession.server_tick()`.
A pack's boss (`boss_overrides`) cycles its template's attack patterns and
keeps to its arena; a commander enrages when a pack mate falls; world bosses
are announced to the map before they come, when they come and when they fall.
Dark Shards (`monolith_types`) call their waves at 75/50/25 % health and come
back elsewhere near their site; training dummies never fall. A client asks
what a creature is with `RealmSession.inspect` (boss name and key, level).

The kill loop (`sim/rewards.rs`, realm_rules `progress` and `loot`): every
player who hit a creature in its last ten seconds earns its experience
(level gap, experience bonus); the killer pockets its oril and the rest lands
in one chest anyone may open for 90 s from 7 m. Levels add health and mana and
two attribute points each (`SpendAttribute`). A fallen player rises after 3 s
where it fell (half health, a 3 s ward) or in town, and goes to town by itself
after 3 min. Packs come back
whole on a fresh anchor. Load with fighting creatures:

```bash
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --dev-spawn-near-packs
cargo run --release -p realm_bots -- --count 500 --seconds 90
```

The client (needs `cargo build --release -p realm_client` and a running server;
WASD, Space, Ctrl, right mouse drag, wheel):

```bash
godot --path game -- --server 127.0.0.1:7777 --map grounds
godot --headless --path game -- --check 15        # joins, walks, prints, exits non-zero on a correction
godot --headless --path game -- --check 30 --check-target stone_dark   # fights a Dark Shard first (its waves)
godot --headless --path game -- --check 180 --character 9 --check-rise here   # loots chests, spends a status point, rises where it fell
godot --path game -- --character 7                 # the same dev character every run
godot --path game --write-movie frames/f.png --fixed-fps 30 -- --check 6 --cam-distance 4 --cam-side 100
```

Art lives in Git LFS on the game's own LFS server (`.lfsconfig`); a fresh
clone needs `git lfs pull`, then `godot --headless --path game --import` once
(also after adding a script with a new `class_name`). Moving more art over:

```bash
cargo run --release -p realm_content -- art content/rename_map.toml ../client game res://assets/models/monsters/troll_forest.glb
```

Rebuilding the map packs from the old game (until the old scenes move in, Phase 6): export its collision world headless, then compile.

```bash
godot --headless --path ../server/world -s "$(pwd -W)/tools/world_export/world_export.gd" -- --out "$(pwd -W)/build/world_export"
cargo run --release -p realm_worldc -- build build/world_export world/maps content/data
```

Godot extension smoke (after a build; Windows shown):

```bash
mkdir -p tools/gdext_smoke/bin && cp target/debug/realm_client.dll tools/gdext_smoke/bin/
godot --headless --path tools/gdext_smoke -s res://smoke.gd -- 1 30
```

## Toolchain

Rust is pinned in `rust-toolchain.toml` (1.100.0, edition 2024); Godot is 4.7.2. Rule: always the newest stable release of the toolchain, Godot, crates and CI images; pre-releases (for example rustls 0.24 dev) are skipped. Local Windows builds
use the `x86_64-pc-windows-gnullvm` host (llvm-mingw); `.cargo/config.toml`
links its unwinder statically so the DLL and the server need no extra
runtime files. CI and Windows release builds use MSVC.

CI (`.github/workflows/ci.yml`) runs on GitHub-hosted Windows, Linux and macOS
runners: format, clippy with warnings as errors, release build, the QUIC
selfcheck, the Godot extension smoke, the movement fingerprint, the content
check, the map pack check, and on Linux a server with 20 fighting bots on the
real grounds map plus one predicted player on the castle through 200 ms
round trip and 2% loss (fails on any correction); a final job fails unless
all three platforms printed identical fingerprints and content hashes.

There is no regression test suite by design. Correctness and speed are checked
with bots under load, cross-platform movement agreement and the performance
gate on the reference machine.
