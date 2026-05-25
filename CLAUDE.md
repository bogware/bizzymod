# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Server-side content for the **Bizzymod Campaign** Left 4 Dead 2 dedicated server (production: `<DEV_HOST>:27015`). The contents of this repo are overlaid on a vanilla L4D2 dedicated server install at `<install>/left4dead2/` on a Linux host.

There is no application code to build in the conventional sense, no test suite, no package manager. "Working on the repo" is editing CFG / VScript / Stripper files and occasionally rebuilding a SourceMod plugin from its `.sp` source.

## Top-level layout (important distinctions)

This repo mixes three things that map to different places at deploy time:

| Path | Ships to server? | Purpose |
| --- | --- | --- |
| `addons/`, `cfg/`, `scripts/`, `host.txt`, `motd.txt`, `myhost.txt`, `mymotd.txt` | **Yes**, copied onto `left4dead2/` | Server runtime content |
| `SourceMod/` | **No** (build-only) | Vendored SourceMod base distribution used as the spcomp compile root |
| `.cicd/`, `.github/`, `.deploy/`, `CLAUDE.md`, `DEPLOY.md`, `LICENSE`, `README.md`, `guide/` | **No** | Repo tooling and docs |

The deploy workflow must exclude the second and third groups when rsync'ing to the server.

## Deployment overview

GitHub Actions workflow `.github/workflows/deploy.yml` is the canonical deploy path. It replaces the original Azure DevOps Release pipeline preserved at `.cicd/AzureDevOpsReleaseExport.json` (read that file as the historical source of truth — every step in the GH workflow has a direct ADO ancestor).

In order, deploy:

1. **Download SourceMod compile root** — Fetches `sourcemod-${SOURCEMOD_VERSION}-linux.tar.gz` from `sourcemod.net/smdrop/1.12/` into `_sm_compile_root/`. Version is pinned in the workflow env (currently `1.12.0-git7230`) to **exactly match the SourceMod version zonemod v1.0.0 ships in its `addons/sourcemod/bin/`**. This avoids compile-time/runtime ABI drift.
2. **Build Bizzymod plugins** — `_sm_compile_root/addons/sourcemod/scripting/` is the compile root. Bizzymod's `.sp` (from this repo's `addons/sourcemod/scripting/`) and SirPlease zonemod's `.sp` (from the zonemod source repo checked out as `zonemod/`) are *copied in alongside SourceMod's own scripting tree* (skipping any name collisions — SM's own files win). For each `.smx` listed in `addons/sourcemod/plugins/bizzymod/`, the matching `.sp` is compiled with the **Linux `spcomp` binary** (no wine — the compile root is the Linux SM package). The result is copied back over the shipped `.smx`.
3. **Fetch zonemod overlay** — Downloads the SirPlease/L4D2-Competitive-Rework Linux release tarball (e.g. `L4D2-Competitive-Rework-v1.0.0-linux.tar.gz`) and extracts the overlay it expects to drop on `left4dead2/`.
4. **Token-replace** — Substitutes `#{Token}#` placeholders in `**/*.cfg`. Tokens map to GitHub secrets / repo variables (see `DEPLOY.md`). The list of tokens is fixed by historical ADO variables: `Server_Name`, `RCON_Pass`, `HostBanner`, `HostMOTD`, the `l4dstats_*` and `SourceBans_*` sets, `userName`, `RemoteTargetFolder`, `initPath`.
5. **Deploy via SSH (username/password)** — Uses `sshpass` + `rsync`/`ssh`. In order on the remote:
   - stop the service
   - `steamcmd app_update 222860 validate` (refreshes vanilla L4D2)
   - rsync **zonemod overlay** onto `<install>/left4dead2/` first
   - **full plugin quarantine**: move every `.smx` from `addons/sourcemod/plugins/` root into `plugins/disabled/` so nothing auto-loads
   - rsync **this repo** onto the same path (this repo wins on conflict)
   - `chmod -R 755`
   - start the service

## Layout you actually have to know

### Runtime content (ships to server)

- `cfg/server1.cfg` — primary `server.cfg`, exec'd by the launch command at startup. Sets identity, gamemode (coop campaign — pinned), difficulty, director tweaks, networking (100 tick), and ends with `exec campaign.cfg`.
- `cfg/campaign.cfg` — **single source of truth for plugin loading**. Every plugin the server runs is named here via explicit `sm plugins load <path>.smx`. No matchmode framework, no `confoglcompmod`, no autoload. Anything you want loaded must be added here.
- `cfg/sourcemod/` — per-plugin SourceMod cvar configs (auto-exec'd by SM when each named plugin loads).
- `addons/sourcemod/plugins/bizzymod/` — compiled Bizzymod `.smx` (rebuilt by the workflow from `addons/sourcemod/scripting/*.sp`). Non-autoloading subdir; `campaign.cfg` references them as `bizzymod/<name>.smx`.
- `addons/sourcemod/plugins/anticheat/` — SourceBans++ (`sbpp_*`) and `lilac.smx`. Non-autoloading subdir; `campaign.cfg` references them as `anticheat/<name>.smx`.
- `addons/sourcemod/plugins/disabled/` — populated **server-side at deploy time** by moving every `.smx` from `plugins/` root here. `campaign.cfg` re-enables only the desired ones via `disabled/<name>.smx`. This is the mechanism that prevents zonemod's matchmode plugins from auto-loading.
- `addons/sourcemod/scripting/` — `.sp` sources for Bizzymod plugins, plus this repo's custom includes under `include/` (including the vendored `multicolors/` chat-color package).
- `addons/thesaccing_v2.vpk` — bundled custom content pack delivered to clients.
- `scripts/vscripts/` — Squirrel VScripts. `vscripts_custom/` is overlay content. Note: VScripts can override `DirectorOptions` at the engine level, independent of SourceMod plugins.

### Build-only

- `_sm_compile_root/` — downloaded fresh per build by CI, never committed. Contains SourceMod 1.12 Linux release with `spcomp` binary. Excluded from deploy rsync.
- `zonemod/` — checked out by CI (SirPlease/L4D2-Competitive-Rework@v1.0.0 source repo) so its scripting tree's `.inc` files (current `left4dhooks.inc`, helpers) are available during compile. Excluded from deploy rsync.

### Repo tooling

- `.cicd/AzureDevOpsReleaseExport.json` — historical Azure DevOps Release export. Source of truth for the deploy pipeline's intent before it was migrated to GitHub Actions.
- `.github/workflows/deploy.yml` — current deploy pipeline.
- `.deploy/` — server-side scripts (systemd unit, launch wrapper, bootstrap). These are pushed to the server *out-of-band*, not as part of the game overlay rsync.
- `guide/` — end-user "how to install your own L4D2 server" doc. **Not** the deployment process for this repo.
- `host.txt` / `motd.txt` — kept at default so Valve's updates can overwrite them harmlessly. Real content is in `myhost.txt` / `mymotd.txt` (referenced by `hostfile`/`motdfile` in `server1.cfg`).

## Conventions worth knowing before editing

- **This server is Campaign-only.** Single mode (coop), single plugin set (`cfg/campaign.cfg`). No matchmode framework, no mode switching, no `confoglcompmod`. Do not re-introduce matchmode infrastructure.
- **Adding a plugin** = drop the `.smx` somewhere under `addons/sourcemod/plugins/<subdir>/` (any non-`disabled/` subdir works since SM only autoloads from `plugins/` root) AND add an explicit `sm plugins load <path>.smx` to `cfg/campaign.cfg`. If the `.smx` is shipped by zonemod (lives in `plugins/` root), the deploy quarantines it to `plugins/disabled/`, so load it as `disabled/<name>.smx`.
- **Removing a plugin** = comment or delete its line in `cfg/campaign.cfg`. The `.smx` can stay on disk; it just won't load.
- **Modifying a Bizzymod plugin** — edit its `.sp` under `addons/sourcemod/scripting/`. The deploy workflow recompiles every `.sp` whose basename matches a `.smx` in `addons/sourcemod/plugins/bizzymod/`. To add a new Bizzymod plugin to the build set, drop a placeholder `<name>.smx` in that directory (any content — it will be overwritten).
- **SourceMod version matters.** `SOURCEMOD_VERSION` in `.github/workflows/deploy.yml` must match the SourceMod version shipped inside zonemod's release tarball. Mismatch causes ABI drift between compile-time headers and runtime extensions, producing silently-wrong plugin behavior. Check zonemod's `addons/sourcemod/extensions/*.so` version string (`grep -aoE "1\.[0-9]+\.[0-9]+\.[0-9]+"`) when bumping `ZONEMOD_RELEASE_TAG`.
- **Tickrate** is set high (100); `server1.cfg`'s "Networking, Rates" section warns that changing it requires updating rate/cmdrate/updaterate proportionally.
- **Token placeholders** — `#{TokenName}#` literals in `.cfg` files are intentional and replaced at deploy time. Do not "fix" them to hardcoded values.
- **Line endings** — `.gitattributes` enforces LF normalization (`* text=auto`). Shell artifacts on the server fail with `bad interpreter: /bin/sh^M` if CRLF leaks through.
- **`screen -r L4D2_Server1`** — to detach use **Ctrl+A then D**. Ctrl+C kills srcds.

## Commands

There are no local dev commands. Everything happens through GitHub Actions. To trigger a deploy: push to `main`, or run the workflow manually from the Actions tab.

To rebuild plugins locally (optional — workflow does this for you):
```
# Download SM 1.12 Linux package, extract somewhere, then:
SM_COMPILE_ROOT=/path/to/extracted/sm .deploy/build-plugins.sh
```
