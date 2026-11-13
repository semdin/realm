# realm

The next core of Thousand Realms: one repository for the shared game rules,
the Rust servers, the Godot client extension and the tools. The plan and its
phases are in `../plans/rebuild-plan.html`; the live game keeps running from
`hpmmo-client` and `hpmmo-server` until the switch-over (Phase 8).

| Path | What it is |
| --- | --- |
| `crates/realm_sim` | Game rules (fixed 30 Hz step): movement (walk, jump, stairs, slopes, swimming, broom) over a collision world. Bit-identical on every platform. No Godot types. |
| `crates/realm_proto` | Wire format: bit packing, input batches, snapshots (owner's body lossless, other entities delta-coded). |
| `crates/realm_data` | Content loading, rename map, typed ids and cross-reference checks, content hash. |
| `crates/realm_content` | `import` (old game data -> `content/data` through the rename map) and `check`. |
| `crates/realm_simcheck` | Scripted movement on a fixed test world + wire round trips + crowd bandwidth; CI compares its output across platforms. |
| `crates/realm_server` | Map server (one process per map and channel): QUIC join with signed tickets, 30 Hz ECS simulation (players, creatures with sleep and AI levels of detail, bolts), interest grid, prioritized delta snapshots; `keygen`, `serve`, `selfcheck`. Runs on generated terrain until Phase 3. |
| `crates/realm_bots` | Load-test clients over the real join path; each runs to the nearest creature and attacks it. |
| `crates/realm_client` | GDExtension the Godot client loads. Phase 0: `RealmInfo` only. |
| `crates/realm_perfgate` | Checks a reference-machine performance report against `perf/budgets.toml`. |
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
cargo run --release -p realm_server -- serve --bind 127.0.0.1:7777 --dev-spawn-near-packs
cargo run --release -p realm_bots -- --count 500 --seconds 120 --ramp 50
cargo run -p realm_content -- check content/rename_map.toml content/data
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
selfcheck, the Godot extension smoke, the movement fingerprint and the content
check, and on Linux a server with 20 fighting bots; a final job fails unless
all three platforms printed identical fingerprints and content hashes.

There is no regression test suite by design. Correctness and speed are checked
with bots under load, cross-platform movement agreement and the performance
gate on the reference machine.
