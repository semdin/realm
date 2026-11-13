# realm

The next core of Thousand Realms: one repository for the shared game rules,
the Rust servers, the Godot client extension and the tools. The plan and its
phases are in `../plans/rebuild-plan.html`; the live game keeps running from
`hpmmo-client` and `hpmmo-server` until the switch-over (Phase 8).

| Path | What it is |
| --- | --- |
| `crates/realm_sim` | Game rules (fixed 30 Hz step). Runs the same on the servers, in the client and in the bots. No Godot types. |
| `crates/realm_proto` | Wire messages and protocol version. |
| `crates/realm_data` | Content tables; the rename map every old id passes through. |
| `crates/realm_server` | Map server (one process per map and channel). Phase 0: `selfcheck` only. |
| `crates/realm_client` | GDExtension the Godot client loads. Phase 0: `RealmInfo` only. |
| `crates/realm_perfgate` | Checks a reference-machine performance report against `perf/budgets.toml`. |
| `content/rename_map.toml` | Old game id -> new id (no franchise-derived id reaches the new core). |
| `perf/budgets.toml` | Client budgets on the reference machine (low preset). |
| `tools/gdext_smoke` | Smallest Godot project that loads `realm_client`. |

## Commands

```bash
cargo build --workspace                              # everything
cargo run -p realm_server -- selfcheck               # QUIC loopback: TLS, stream, datagrams
cargo run -p realm_perfgate -- perf/budgets.toml report.json [--report-only]
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
selfcheck and the Godot extension smoke.

There is no regression test suite by design. Correctness and speed are checked
with bots under load, cross-platform movement agreement and the performance
gate on the reference machine.
