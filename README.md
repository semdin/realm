# realm

The next core of Thousand Realms: one repository for the shared game rules,
the Rust servers, the Godot client extension and the tools. The plan and its
phases are in `../plans/rebuild-plan.html`.

| Path | What it is |
| --- | --- |
| `crates/realm_sim` | Game rules (fixed 30 Hz step): movement (walk, jump, stairs, slopes, swimming, broom) over a collision world, navigation queries, the castle's moving staircases (a pure function of the tick). Bit-identical on every platform. No Godot types. |
| `crates/realm_proto` | Wire format: bit packing, input batches, snapshots (owner's body lossless, other entities delta-coded), and the control channel (`control`: the join stream kept open for framed, reliable messages both ways). |
| `crates/realm_rules` | Game rules beyond movement: the character sheet (what is saved, sent to its owner and changed by the server), items, looks, and the typed content they read. Grows with each Phase 5 slice. |
| `crates/realm_data` | Content loading, typed ids and cross-reference checks, content hash. |
| `crates/realm_content` | `check` (cross references and the content hash), `scan` (fails on any reserved term in text files or file names, against the hashed list in `tools/content_guard/reserved.sha256`; CI runs it) and `hash-list` (writes that list from a word file). |
| `crates/realm_simcheck` | Scripted movement on a fixed test world + wire round trips + crowd bandwidth; CI compares its output across platforms. |
| `crates/realm_server` | Map server (one process per map and channel): QUIC join with signed tickets, 30 Hz ECS simulation (players, creatures with sleep and AI levels of detail, bolts), interest grid, prioritized delta snapshots; `keygen`, `serve`, `selfcheck`. Loads one compiled map pack; creatures follow navigation-mesh paths. |
| `crates/realm_worldc` | World compiler: Godot export -> map packs (colliders, terrain, water, moving geometry, navigation mesh baked with rerecast); `check` walks bodies from every spawn point, tests paths and samples every creature pack's area the way the server places creatures (walkable ground, never a roof or a prop). |
| `crates/realm_bots` | Load-test clients over the real join path; each runs to the nearest creature and attacks it. |
| `crates/realm_netclient` | The client's network core without Godot: prediction with exact reconciliation, snapshot store, remote-entity interpolation (`ClientCore`), and the QUIC connection on a background thread (`NetHandle`). |
| `crates/realm_client` | GDExtension the Godot client loads: `RealmSession` (joins, steps the 30 Hz prediction, reports own body, others, stats and the map as meshes). |
| `crates/realm_netem` | UDP proxy that adds delay, jitter and loss in both directions. |
| `crates/realm_netcheck` | One scripted player through `ClientCore`; fails on any correction (Phase 4 exit). |
| `game/` | The new Godot client (Mobile renderer). Players are the real hero (`scripts/view/hero_view.gd`), creatures their real models (`creature_view.gd`, from `content/data/creature_views.json`; a boss wears its authored boss body sized by `boss_overrides`), Dark Shards and training dummies their own views (`stone_view.gd`: idle glow, waves, shatter, fall-in; `dummy_view.gd`); the map's boss and stone notices show on the notice band; the game's windows (Arcane frame, Turkish by default: `scripts/ui`, `locale/tr.po`) read the sheet through `scripts/view/player_sheet.gd`, the inventory (I) first; the map's NPCs (`content/data/npcs.json`, `scripts/view/npc_view.gd`) stand on the ground under their place, and the quest log the server keeps shows on the dialogue card, the tracker, the quest log (J) and the quest scroll (`scripts/systems/quest_manager.gd`); every map draws itself (`maps/<map>/<map>.tscn`: the grounds on Terrain3D with the lake, courtyard, Orvell and the far-tree impostors; the castle interior's Gothic build, feast and moving staircases on the client core's own staircase poses; the caverns and the three dungeons), lit by the day-night on GMT+3 (`scripts/world/day_night.gd`) under one quality preset (`scripts/world/quality_preset.gd`, Settings > Graphics); `--placeholder-world` draws the pack's grey collision geometry instead. Drawn solids without a collider get boxes from `world/patches/<map>.json` (`realm_worldc patch`). Art is in LFS. |
| `crates/realm_coord` | The coordinator: who is online on which map (every character's seat: on one map or in transit), the parties, shouts and party lines across maps, and the handoff between maps (a seat reserved on the destination, the old map's save landed before the sheet moves, a ticket signed with keys/ticket.key). Map servers link to it with `--coord` and keys/coord.key; players never do. Without it a map server still runs alone (local chat, trips on its own map). |
| `crates/realm_login` | The login service: accounts (argon2id), sessions, each account's two characters (name and house rules), and the ticket a client joins its map with (signed with keys/ticket.key; the map's address from the coordinator's `GET /admin/maps`). Writes new characters into the map servers' `--characters` folder. |
| `crates/realm_persist` | The persistence service: the only writer of the realm's PostgreSQL (REALM_DATABASE_URL; schema migrations at start). Map servers run with `--persist <addr>` instead of `--characters <dir>`; a save is answered once committed and never goes back in time (an older revision is refused). |
| `launcher/` | The launcher (C++; Windows GDI+, Linux/macOS SDL3): installs and updates the game from this repository's GitHub Releases (signed manifests, chunked delta updates), shows the realm's state from `https://api.agsilvery.com/api/status`, starts the game. Its background is drawn from noise (`assets/make_background.py`). Released by `.github/workflows/client-release.yml` (manual dispatch) with the game. |
| `crates/realm_http` | The one-request-per-connection JSON HTTP the coordinator's admin surface and the login service share. |
| `crates/realm_perfgate` | Checks a reference-machine performance report against `perf/budgets.toml`. |
| `world/maps/*.realmmap` | Compiled map packs (zstd + postcard), one per map. |
| `tools/world_export` | Godot script that exports a world project's collision world for `realm_worldc`. |
| `content/data/` | The game's content (12 JSON files, imported 2026-11-13). Keys starting with `_` are author notes. |
| `perf/budgets.toml` | Client budgets on the reference machine (low preset). |
| `tools/gdext_smoke` | Smallest Godot project that loads `realm_client`. |
| `tools/release` | `stage_client.sh`: makes a Godot export of the client a complete game (see Releasing the client). |

## Commands

```bash
cargo build --workspace                              # everything
cargo run -p realm_server -- selfcheck               # QUIC loopback: TLS, stream, datagrams
cargo run -p realm_perfgate -- perf/budgets.toml report.json [--report-only]
cargo run --release -p realm_simcheck [-- --trace stairs | --bench]   # movement fingerprint / cost
cargo run --release -p realm_server -- keygen keys            # dev ticket key + TLS cert (keys/ is gitignored)
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --dev-spawn-near-packs   # or --dev-spawn-near troll_forest | grak | stone_dark | training_dummy
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --characters build/characters   # characters persist (JSON per character); Ctrl+C saves all
cargo run --release -p realm_coord                      # coordinator: chat, parties across maps (127.0.0.1:7900, keys/coord.key)
cargo run --release -p realm_coord -- --boards build/boards.json   # the same, keeping the weekly dungeon boards across restarts
REALM_SERVICE_TOKEN=<t> cargo run --release -p realm_coord -- --admin 127.0.0.1:8082 --ga build/ga.json   # with the admin surface (maintenance, GA, maps, metrics, the operator panel /panel) and the GA list
docker run -d --name realm-pg -p 127.0.0.1:55432:5432 -e POSTGRES_USER=realm -e POSTGRES_PASSWORD=realm-dev -e POSTGRES_DB=realm postgres:18.7   # local PostgreSQL
REALM_DATABASE_URL=postgres://realm:realm-dev@127.0.0.1:55432/realm cargo run --release -p realm_persist   # persistence service on 127.0.0.1:7970 (map servers: --persist 127.0.0.1:7970)
REALM_SERVICE_TOKEN=<t> cargo run --release -p realm_login -- --characters build/characters   # login service on 127.0.0.1:7950 (the coordinator's admin surface on 127.0.0.1:8082)
bash tools/ops/package.sh                             # the server release for the Linux host (Docker): build/release/realm-<date>-<commit>.tar.gz
bash tools/ops/backup_check.sh                        # backups: WAL archive, base backup, point-in-time restore (Docker, ~20 s)
bash tools/ops/host_rehearsal.sh                      # the host on an empty database in a systemd container: install, login, drain deploy, rollback, backups (~3 min; deploy/README.md)
cargo run --release -p realm_server -- serve --map grounds --bind 127.0.0.1:7777 --coord 127.0.0.1:7900   # a map server linked to it
cargo run --release -p realm_netcheck -- --social       # two players on two maps: invite, party, party line, shout, local stays local
cargo run --release -p realm_netcheck -- --duel         # two players on one map: challenge, accept, fight to 1 health, result
cargo run --release -p realm_netcheck -- --travel --characters build/travelcheck   # grounds (7777) + castle_interior (7778) with --coord and --characters build/travelcheck: doors both ways, hearths, broom, Waylink, a takeover; the sheet whole every time
cargo run --release -p realm_netcheck -- --dungeon --characters build/dungeoncheck   # grounds (7777) + dng_trial (7779, --dev-dungeon-scale 0.05) with --coord and --characters build/dungeoncheck: gate, solo Normal run to a medal, rewards, chest, record, out
cargo run --release -p realm_netcheck -- --dungeon --quick --characters build/dungeoncheck   # the same servers, ~30 s: gate, launch, countdown, first wave, second gate, out (while working on dungeons)
cargo run --release -p realm_netcheck -- --metrics --admin 127.0.0.1:8082 --token <t> --server 127.0.0.1:7777 --persist-addr 127.0.0.1:7970   # the coordinator's metrics JSON, Prometheus text and /panel: the grounds' numbers, a join, its save counted (<1 min)
cargo run --release -p realm_bots -- --count 500 --seconds 120 --ramp 50   # each bot learns --skill shockwave=3 and opens with it
cargo run -p realm_content -- check content/data
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
respawns. The client draws a telegraph as a projected ground mark
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
godot --headless --path game -- --check-quests --character 11   # the first chapter: talks to Master Teral Venn, wears the cloak, hits a dummy; claims q001-q003
godot --headless --path game -- --check-workshop --character 900002   # O opens Kestrin's workshop: refines, imbues and reweaves the wand (prepared character)
godot --headless --path game -- --check-social --character 900107   # with realm_coord, the map server --coord 127.0.0.1:7900 and realm_netcheck --social-partner: local line + bubble, /invite, party frame, party line and shout, /leave
godot --headless --path game -- --social-guest "Wanderer 107" --character 900108   # a second client that says a local line and invites; the check then takes --check-invite-from "Wanderer 108" (card, player menu, accept)
godot --path game -- --check-travel --character 900201   # with realm_coord and the grounds (7777) + castle_interior (7778) servers --coord 127.0.0.1:7900 --characters build/travelcheck and `make_prepared_character.py build/travelcheck 900201 --travel-kit`: castle door and back (loading screen, scene rebuilt per map), Hearth window to Orvell Square, broom mount/dismount, a Waylink; PNGs in build/captures/travel
godot --path game -- --check-skills --character 900801   # with build/logs/aup_skills.sh (level 12, Stun Bolt 9): V opens the skill window, "+" raises Stun Bolt to Master and learns Shockwave, a bar click learns Disarm; levels, points and the taskbar badge follow the sheet; PNGs in build/captures/skills
godot --path game -- --check-others --character 900811   # with build/logs/aup_others.sh: starts a second client (--others-guest, character 900812), sees its nameplate (name, level, house, title), wand, mantle and look, then its new look and empty hand after the partner changes; PNGs in build/captures/others
godot --path game -- --check-map --character 900901   # with build/logs/aup_map.sh: the minimap, the world map (M) and its markers, a click sets a waypoint, its footprints, the walk along the route until it clears, the zone banner, the dungeon guide's "Show the way to the gate"; `aup_map.sh castle|caverns` + `--map castle_interior|spider_caverns` surveys that map; PNGs in build/captures/map
godot --path game -- --check-audio --character 901001   # with build/logs/aup_audio.sh (level 12, broom, Hearth Dust, in the courtyard): zone music and ambience bed, no steps standing / steps walking, the drowned ones' alert, grunts and death cries and the tension mix rising and falling, the Hearth Pavilion trip's sound and Orvell's music cross-fading in, the broom's wind following speed; prints the audio layer's per-frame cost
godot --path game -- --check-castle --map castle_interior --character 901301 --server 127.0.0.1:7831   # with build/logs/kup_castle.sh: the castle drawn (game/maps/castle_interior) where the server's floors and walls are - feet on the drawn floor at spawn and after a short walk, five fixed views (Entrance Hall, Feast Hall, stairwell, Sealed Wing door, corridor) probed against session.pick and captured to build/captures/castle with their frame times, memory; add --placeholder-world for the same probes over the grey pack
godot --path game -- --server 127.0.0.1:8701 --check-controls --character 922101   # with build/logs/w22_stack.sh (travel kit at the castle approach): leaves and re-enters protected ground (no entry sound), the basic attack held on a dummy by Ctrl and by the left button (cadence, none after release), Ctrl on the broom casts nothing, Z and the key under Escape take loot, the zoom limits, damage numbers near and far, Kestrin's Forge's sign at 50-300 m (fade); PNGs via --capture-dir
godot --path game -- --server 127.0.0.1:8701 --check-dungeon --check-dungeon-replay --character 922301   # with W22_TRIAL_ARGS="--dev-dungeon-start done" build/logs/w22_stack.sh start: the run ends at once; no window, the notice line and chat lines, K's guide with "Run it again", pressed: the launch (<40 s)
godot --path game -- --character 7                 # the same dev character every run
godot --path game --write-movie frames/f.png --fixed-fps 30 -- --check 6 --cam-distance 4 --cam-side 100
```

Art lives in Git LFS on the game's own LFS server (`.lfsconfig`); a fresh
clone needs `git lfs pull`, then `godot --headless --path game --import` once
(also after adding a script with a new `class_name`). 

Rebuilding the map packs: export the world project's collision world headless (one `<map id>.json` and `.bin` per map), then compile.

```bash
godot --headless --path <world_project> -s "$(pwd -W)/tools/world_export/world_export.gd" -- --out "$(pwd -W)/build/world_export"
cargo run --release -p realm_worldc -- build build/world_export world/maps content/data
```

Godot extension smoke (after a build; Windows shown):

```bash
mkdir -p tools/gdext_smoke/bin && cp target/debug/realm_client.dll tools/gdext_smoke/bin/
godot --headless --path tools/gdext_smoke -s res://smoke.gd -- 1 30
```

## Releasing the client

The game players run is a Godot export of `game/` (`game/export_presets.cfg`:
"Windows Desktop", "Linux", "macOS"; executable `ThousandRealms`), staged
with the files the Rust core reads with `std::fs`:

```bash
cargo build --release -p realm_client                 # the extension, into target/release (the export copies it from there)
godot --headless --path game --import                 # once, and after a new class_name
godot --headless --path game --export-release "Windows Desktop" "$(pwd -W)/build/client_export/win/ThousandRealms.exe"
godot --headless --path game --export-release "Linux" "$PWD/build/client_export/linux/ThousandRealms.x86_64"
godot --headless --path game --export-release "macOS" "$PWD/build/client_export/mac.zip" && unzip -q build/client_export/mac.zip -d build/client_export/mac
bash tools/release/stage_client.sh build/client_export/win windows game/release/tls.crt.der [realm_client.dll to ship]
bash tools/release/stage_client.sh build/client_export/mac macos game/release/tls.crt.der [universal librealm_client.dylib]
build/client_export/win/ThousandRealms.exe --headless -- --login-url http://127.0.0.1:<port> --check-play USER PASSWORD   # smoke (build/logs/e8_check.sh)
```

- **The extension library.** `game/realm.gdextension` points at
  `../target/release`; Godot exports a library outside `res://` as it
  does any other: it copies it beside the executable (macOS: the bundle's
  `Contents/Frameworks`), and the exported game loads it from there. An export
  fails when the library is missing. To export for another platform, put that
  platform's library in `target/release` first (`realm_client.dll`,
  `librealm_client.so`, `librealm_client.dylib` sit side by side), or give the
  build to ship as `stage_client.sh`'s 4th argument, which replaces the copy.
  The macOS export is universal: the dylib is `lipo -create` of the
  `aarch64-apple-darwin` and `x86_64-apple-darwin` builds (Godot only allows a
  universal export when the project imports ETC2/ASTC as well, hence
  `import_etc2_astc` in `project.godot`; the pck carries S3TC/BPTC only).
  Terrain3D's libraries come from `game/addons/terrain_3d/bin` (Git LFS:
  `git lfs pull` first; `stage_client.sh` refuses pointers and missing ones).
- **The release root** (`game/scripts/systems/realm_paths.gd`): an exported
  game (feature `template`) reads `content/data`, `world/maps` and
  `keys/tls.crt.der` beside its executable; on macOS beside the
  `Thousand Realms.app` bundle (the launcher starts
  `Thousand Realms.app/Contents/MacOS/Thousand Realms`), so the bundle stays
  exactly as the export signed it, realm_client's library included (put in
  `target/release/` before a macOS export). A dev run keeps the checkout
  (`res://..`); `--keys`, `--content` and `--maps` override either.
  `stage_client.sh` fills the root fresh each time.
- **What ships**: the executable, `ThousandRealms.pck` (all resources; the
  grounds' scatter `.bin`s, the tree tiles and the font licence through
  `include_filter`), the two extension libraries, `content/data/*.json`,
  `world/maps/*.realmmap`, and of `keys/` only the realm's public certificate
  (`game/release/tls.crt.der`, the one the live map servers present; the
  client pins it, server name "localhost"). Never `ticket.key`, `coord.key`
  or a TLS private key: `stage_client.sh` copies exactly one file into `keys/`
  and refuses anything that is not a DER certificate. The dev checks
  (`*_check.gd`) and the `map_solids` tool are left out by `exclude_filter`;
  an exported game refuses the dev switches (`--character`, `--server`,
  `-guest`, every `--check*` but `--check-play`) with exit code 2.
- **The login service** an exported game talks to by default is
  `https://api.agsilvery.com` (`LoginApi.RELEASE_URL`; a dev run keeps
  `http://127.0.0.1:7950`); `--login-url` overrides both. The game prints its
  release root and login service as it starts.
- **`--check-play USER PASSWORD`** (`scripts/systems/play_smoke.gd`, also in
  an export): through the front door, logs in (registers an unknown account),
  picks the first character (creates one on an empty roster), enters the
  world, sees the sheet and the map's own scene drawn, quits 0; fails fast on
  any refusal of the card or the roster, and on the world's end screen (a
  join that fails is first tried again with a fresh ticket, as for a
  player), at most 80 s. On 2026-11-15 the staged Windows export did it
  against a local stack (persist, coordinator, grounds, login) in ~2 s for a
  new and for an existing account. Its parts: `ThousandRealms.exe` 104 MiB
  (the release template), `ThousandRealms.pck` 875 MiB,
  `realm_client.dll` 33 MiB, Terrain3D's dll 3.7 MiB, `content/data` 0.8 MB,
  `world/maps` 5.4 MB, `keys` 366 bytes: 1.0 GiB in all.

## Toolchain

Rust is pinned in `rust-toolchain.toml` (1.100.0, edition 2024); Godot is 4.8 beta 3 (a deliberate exception: it carries the fix for the Mobile renderer's Metal deadlock). Rule: always the newest stable release of the toolchain, Godot, crates and CI images; pre-releases (for example rustls 0.24 dev) are skipped. Local Windows builds
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
