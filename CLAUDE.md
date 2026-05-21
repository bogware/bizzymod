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

1. **Build Bizzymod plugins** — Uses the in-repo `SourceMod/sourcemod/addons/sourcemod/scripting/` as the compile root. Bizzymod's `.sp` (from this repo's `addons/sourcemod/scripting/`) and SirPlease zonemod's `.sp` are *copied in alongside SourceMod's own scripting tree* (skipping any name collisions — SM's own files win). For each `.smx` listed in `addons/sourcemod/plugins/bizzymod/`, the matching `.sp` is compiled with `spcomp` and the result is copied back over the shipped `.smx`. spcomp.exe is a Windows binary; the workflow uses `wine` on the linux runner to run it.
2. **Fetch zonemod overlay** — Downloads the SirPlease/L4D2-Competitive-Rework Linux release tarball (e.g. `L4D2-Competitive-Rework-v1.0.0-linux.tar.gz`) and extracts the overlay it expects to drop on `left4dead2/`.
3. **Token-replace** — Substitutes `#{Token}#` placeholders in `**/*.cfg`. Tokens map to GitHub secrets / repo variables (see `DEPLOY.md`). The list of tokens is fixed by historical ADO variables: `Server_Name`, `RCON_Pass`, `HostBanner`, `HostMOTD`, the `l4dstats_*` and `SourceBans_*` sets, `userName`, `RemoteTargetFolder`, `initPath`.
4. **Deploy via SSH (username/password)** — Uses `sshpass` + `rsync`/`ssh`. In order on the remote:
   - stop the service
   - `steamcmd app_update 222860 validate` (refreshes vanilla L4D2)
   - rsync **zonemod overlay** onto `<install>/left4dead2/` first
   - rsync **this repo** onto the same path (this repo wins on conflict)
   - `chmod -R 755`
   - start the service

## Layout you actually have to know

### Runtime content (ships to server)

- `cfg/cfgogl/<mode>/` — per-matchmode configs loaded by confoglcompmod. One folder per mode listed in `addons/sourcemod/configs/matchmodes.txt` (`bizzymod`, `numbersmod`, `busmod`, `barrymod`, `spacemod`, `thundermod`, `acv`, `kneemod`, `bobbymod`, `seltzermod`, `bananamod`, `heizemod`, `flatmod`, `onemod`, `powermod`, `invokemod`, `deadmanX`, `zonereal`, plus several zonemod variants). Each contains roughly `confogl.cfg`, `confogl_plugins.cfg`, `shared_*.cfg`, and `<mode>.cfg`. **Edits to a mode's behavior almost always live here.**
- `cfg/stripper/<mode>/maps/<mapname>.cfg` — [Stripper:Source](https://www.bailopan.net/stripper/) rules that add/remove/modify entities per map per mode. `global_filters.cfg` applies across all maps in that mode.
- `cfg/sourcemod/` — per-plugin SourceMod cvar configs.
- `cfg/server1.cfg` — primary `server.cfg`, exec'd by the launch command. Networking is configured for **100 tick** (rates of 100/100000).
- `cfg/sharedplugins.cfg`, `cfg/generalfixes.cfg` — `sm plugins load` lists exec'd at matchmode load. The set is named by `confogl_match_execcfg_plugins` in `server1.cfg`.
- `addons/sourcemod/plugins/bizzymod/` — compiled Bizzymod `.smx` (rebuilt by the workflow from `addons/sourcemod/scripting/*.sp`).
- `addons/sourcemod/plugins/anticheat/` — SourceBans++ (`sbpp_*`) and `lilac.smx`.
- `addons/sourcemod/scripting/` — `.sp` sources for Bizzymod plugins, plus this repo's custom includes under `include/` and `includes/`.
- `addons/thesaccing_v2.vpk` — bundled custom content pack delivered to clients.
- `scripts/vscripts/` — Squirrel VScripts. `bizzymodRealism.nut` / `zonemodRealism.nut` set `DirectorOptions` for realism modes. `vscripts_custom/` is overlay content.

### Build-only

- `SourceMod/sourcemod/` — vendored SourceMod base distribution (full standard `addons/sourcemod/` tree). Used as the compile root because `spcomp.exe` resolves `#include <...>` relative to its own scripting directory. **Do not deploy this to the server** — the server already has SourceMod installed there as part of the zonemod overlay, and this is the wrong version path.

### Repo tooling

- `.cicd/AzureDevOpsReleaseExport.json` — historical Azure DevOps Release export. Source of truth for the deploy pipeline's intent before it was migrated to GitHub Actions.
- `.github/workflows/deploy.yml` — current deploy pipeline.
- `.deploy/` — server-side scripts (systemd unit, launch wrapper, bootstrap). These are pushed to the server *out-of-band*, not as part of the game overlay rsync.
- `guide/` — end-user "how to install your own L4D2 server" doc. **Not** the deployment process for this repo.
- `host.txt` / `motd.txt` — kept at default so Valve's updates can overwrite them harmlessly. Real content is in `myhost.txt` / `mymotd.txt` (referenced by `hostfile`/`motdfile` in `server1.cfg`).

## Conventions worth knowing before editing

- **Adding a matchmode** requires (at minimum) a new `cfg/cfgogl/<mode>/` directory, an entry in `addons/sourcemod/configs/matchmodes.txt`, and usually a parallel `cfg/stripper/<mode>/` for map tweaks.
- **Adding a plugin** requires both a `.smx` under `addons/sourcemod/plugins/<subdir>/` *and* an explicit `sm plugins load` from one of the cfg files (`sharedplugins.cfg`, `generalfixes.cfg`, or a mode's `confogl_plugins.cfg`). Dropping a `.smx` in is not enough.
- **Modifying a Bizzymod plugin** — edit its `.sp` under `addons/sourcemod/scripting/`. The deploy workflow recompiles every `.sp` whose basename matches a `.smx` in `addons/sourcemod/plugins/bizzymod/`. To add a new Bizzymod plugin to the build set, drop a placeholder `<name>.smx` in that directory (any content — it will be overwritten).
- **`cfg/cfgogl/<mode>/confogl_plugins.cfg`** toggles plugins per-mode via `sm plugins load` / `sm plugins unload`. If a behavior is on in one mode but not another, that file is usually why.
- **Tickrate** is set high (100); `server1.cfg`'s "Networking, Rates" section warns that changing it requires updating rate/cmdrate/updaterate proportionally.
- **Token placeholders** — `#{TokenName}#` literals in `.cfg` files are intentional and replaced at deploy time. Do not "fix" them to hardcoded values.
- **Line endings** — `.gitattributes` enforces LF normalization (`* text=auto`). Shell artifacts on the server fail with `bad interpreter: /bin/sh^M` if CRLF leaks through.

## Commands

There are no local dev commands. Everything happens through GitHub Actions. To trigger a deploy: push to `main`, or run the workflow manually from the Actions tab.

To rebuild plugins locally (Windows only, optional — workflow does this for you):
```
cd SourceMod\sourcemod\addons\sourcemod\scripting
# copy your .sp into this dir (and any deps), then:
.\spcomp.exe yourplugin.sp
```
