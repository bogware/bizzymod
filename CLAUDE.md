# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What this repo is

A **monorepo of server-side content for the Bizzymod Left 4 Dead 2 dedicated
servers**. Each **game mode is a "server"** under `servers/<name>/`, and each
server is **self-contained** — its overlay (cfg, plugins, scripts) is complete on
its own; shared plugins are copied into each server rather than factored out.

- `servers/campaign/` — the coop Campaign server (production-hardened; the first
  and, for now, only fully-wired server).
- `servers/competitive/`, `servers/vanilla/` — **scaffolds** (READMEs only, no
  content yet).

There is no application code to build in the conventional sense: "working on the
repo" is editing CFG / VScript / Stripper files and occasionally rebuilding a
SourceMod plugin from its `.sp` source. All build + deploy happens through GitHub
Actions.

## Two environments, one runner

Every server deploys to **two real, public environments**: `dev` and `prod`
(players don't notice which is which; both are live).

| | prod | dev |
|---|---|---|
| host | `<PROD_HOST>` | `<DEV_HOST>` |
| SSH | `1989`, root | `1989`, root |
| campaign install | `/home/campaign/Steam/steamapps/common/l4d2/left4dead2` | same path |

Deploys run on a **self-hosted Linux runner** (bogware org, labels `self-hosted` +
`Linux`) via SSH+password. Per-target credentials live in **GitHub Environments
`<server>-<environment>`** (e.g. `campaign-prod`, `campaign-dev`); DB creds are
**shared** repo-level secrets. Full secret/var matrix: **`DEPLOY.md`**.

> Note: an older `CLAUDE.md` called `<DEV_HOST>` "production" — that host is
> now **dev**. `<PROD_HOST>` is prod.

## Top-level layout

| Path | Ships to a server? | Purpose |
| --- | --- | --- |
| `servers/<name>/` | **Yes** — `servers/<name>/` is rsync'd onto `<install>/left4dead2/` | Per-server runtime content + a `deploy.env` manifest (not shipped) |
| `.github/workflows/` | No | All workflows for all servers (deploy, diagnose, migrate-stats) |
| `.deploy/` | No | Build/deploy helper scripts + server-side systemd/launch/bootstrap |
| `.cicd/` | No | Historical Azure DevOps release export (deploy source-of-truth ancestor) |
| `guide/` | No | End-user "stand up your own L4D2 box" doc (not this repo's deploy) |
| `legacy/`, `older-legacy/` | No | Parked historical content |
| `CLAUDE.md` `DEPLOY.md` `README.md` `LICENSE` | No | Repo docs |

Build-only dirs, created fresh by CI and never committed: `zonemod/` (SirPlease
source checkout, for SourcePawn includes), `_zonemod_overlay/` (zonemod release
tarball), the SourcePawn compiler (via `rumblefrog/setup-sp`).

## Per-server layout (`servers/campaign/`)

- `cfg/server1.cfg` — primary `server.cfg`, exec'd at startup (`+servercfgfile
  server1.cfg`). Identity, gamemode (coop campaign — pinned), difficulty
  (`z_difficulty "Impossible"` = Expert), director tweaks, 100-tick networking;
  ends with `exec campaign.cfg`.
- `cfg/campaign.cfg` — **single source of truth for plugin loading.** Every plugin
  is named here via explicit `sm plugins load <path>.smx`; anything to disable an
  auto-loading plugin is done here too (e.g. the smoker-tongue fix — see below).
  No matchmode framework, no autoload reliance beyond what's intentional.
- `cfg/sourcemod/` — per-plugin SourceMod cvar configs.
- `addons/sourcemod/plugins/optional/bizzymod/` — compiled Bizzymod `.smx`
  (rebuilt by the workflow from `addons/sourcemod/scripting/*.sp`). `optional/` is
  excluded from SM auto-load, so `campaign.cfg` loads them explicitly.
- `addons/sourcemod/plugins/anticheat/` — SourceBans++ (`sbpp_*`) + `lilac`.
- `addons/sourcemod/plugins/disabled/` — populated server-side at deploy time
  (matchmode quarantine).
- `addons/sourcemod/scripting/` — `.sp` sources for Bizzymod plugins + local
  `include/` (incl. vendored `multicolors/`), and the vendored `bizzymod_stats/`.
- `scripts/vscripts/` — Squirrel VScripts (can override `DirectorOptions` at engine
  level, independent of SourceMod).
- `deploy.env` — **per-server manifest** (shell), sourced by the workflows. Declares
  `APPLY_ZONEMOD_OVERLAY`, `ZONEMOD_RELEASE_TAG`, `QUARANTINE_MATCHMODE`,
  `QUARANTINE_FIXES`, `SOURCEMOD_VERSION`. **Not shipped** (rsync excludes it).

## Deployment

`.github/workflows/deploy.yml` is the canonical path — **manual only**
(`workflow_dispatch`, inputs `server` + `environment`; no push trigger). In order:

1. Load `servers/<server>/deploy.env`.
2. Verify runner tools (`sshpass rsync curl tar ssh`).
3. (if `APPLY_ZONEMOD_OVERLAY`) checkout zonemod source + set up SourcePawn 1.12.
4. Compile the server's Bizzymod plugins: `.deploy/build-plugins.sh servers/<server>`.
5. (if zonemod) download the zonemod Linux overlay tarball.
6. Token-replace `#{...}#` in `servers/<server>/**/*.cfg`.
7. SSH to the Environment's `SSH_HOST`; stop server; copy logs; (optional) steamcmd
   validate; (if zonemod) rsync the zonemod overlay with `--delete-after` (which
   also **wipes stale/bad content already on the target**); (if
   `QUARANTINE_MATCHMODE`) quarantine `confoglcompmod`/`match_vote`/`reservedslots`
   + `QUARANTINE_FIXES` into `plugins/disabled/`; rsync `servers/<server>/` on top
   (this repo wins); chmod; start; verify `srcds_run`.

`diagnose.yml` and `migrate-stats.yml` take the same `server`/`environment` inputs.

## Conventions worth knowing before editing

- **Campaign is coop-only.** Single mode (coop), single plugin set
  (`servers/campaign/cfg/campaign.cfg`). No matchmode framework, no mode switching.
  Do not re-introduce matchmode infrastructure into campaign.
- **Self-contained servers.** Do not factor shared plugins into a common tree; each
  `servers/<name>/` carries its own copy. Adding a second server = copy + adjust,
  not refactor-into-shared.
- **Adding a plugin** = drop the `.smx` under `servers/<server>/addons/sourcemod/
  plugins/<subdir>/` AND add `sm plugins load <path>.smx` to that server's
  `campaign.cfg`. If the `.smx` is zonemod-shipped (lands in `plugins/` root/`fixes/`
  and auto-loads), either quarantine it (deploy `QUARANTINE_*`) or `sm plugins
  unload` it in `campaign.cfg`.
- **Smoker tongue fix (live-verified).** `campaign.cfg` unloads zonemod's three
  competitive tongue-detour plugins (`fixes/l4d_tongue_{bend,block,float}_fix.smx`)
  — in coop they break the smoker PULL (tongue grabs, never reels). Keep them off.
- **Modifying a Bizzymod plugin** — edit its `.sp` under `servers/<server>/addons/
  sourcemod/scripting/`. The workflow recompiles every `.sp` whose basename matches
  a `.smx` in `plugins/optional/bizzymod/`. New plugin = drop a placeholder `.smx`
  there.
- **SourceMod version matters.** `SOURCEMOD_VERSION` in the server's `deploy.env`
  must match what the runtime (zonemod) ships, or ABI drift produces silently-wrong
  plugin behavior.
- **Tickrate** is 100; `server1.cfg`'s Rates section warns that changing it requires
  updating rate/cmdrate/updaterate proportionally.
- **Token placeholders** — `#{TokenName}#` in `.cfg` are intentional, replaced at
  deploy. Do not "fix" them to literal values.
- **Line endings** — `.gitattributes` enforces LF; CRLF leaking to the box breaks
  shell scripts (`bad interpreter: /bin/sh^M`).
- **`screen -r L4D2_Server1`** — detach with **Ctrl+A then D** (Ctrl+C kills srcds).
- **Secrets never go in the conversation/tool-command lines** — auth out-of-band or
  have the user run credentialed commands (see the memory of the same name).

## Commands

No local dev server. To deploy: `gh workflow run deploy.yml -f server=campaign -f
environment=dev` (or the Actions tab). To rebuild plugins locally (CI does this for
you): download SM 1.12 Linux, then `SM_COMPILE_ROOT=/path .deploy/build-plugins.sh
servers/campaign`.
