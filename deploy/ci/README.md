# deploy/ci

The realm host's self-hosted Actions runner for `client-release.yml`
(the game export keeps `game/.godot` between releases there, so unchanged
assets re-import byte-identically and players download only what changed).
`<ci-dir>` below is the tools directory under `/opt` that `client-release.yml`
names.

| On the host | What |
| --- | --- |
| `/opt/actions-runner-realm` | the runner (user `ghrunner`, label `realm-release`, in the CI systemd slice at Nice 10) |
| `<ci-dir>/godot-4.8.beta3/godot` | Godot 4.8 beta 3 headless; export templates in `~ghrunner/.local/share/godot/export_templates/4.8.beta3` |
| `<ci-dir>/build_linux_launcher.sh` | root-owned copy of `build_linux_launcher.sh` here; the only thing `ghrunner` may run through sudo (a rule in `/etc/sudoers.d/`): builds the AppImage in Docker from sources under the runner's workspace only |
| `~ghrunner/.git-credentials` | the LFS server's credentials (`lfs.agsilvery.com`) for `git lfs pull` |

Registering the runner again (as root on the host): take a token with
`gh api -X POST repos/semdin/realm/actions/runners/registration-token -q .token`,
then in `/opt/actions-runner-realm`: `sudo -u ghrunner ./config.sh --unattended
--replace --url https://github.com/semdin/realm --token <token> --name
ryzen-realm --labels realm-release --work _work` and `./svc.sh install ghrunner`.
The repository is public: workflows from outside contributors' pull requests
need approval (fork-pr-contributor-approval = all external contributors),
and no workflow here runs on pull_request against the self-hosted runner.
After changing `build_linux_launcher.sh` here, install it with
`install -o root -g root -m 0755 build_linux_launcher.sh <ci-dir>/`.
