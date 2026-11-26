# servers/moonland — Bizzy's Moonland

Moon's realism playmodes (Moon Mod, numbersmod, bizzymod) from the public
[BizzyMoon](https://github.com/MoonL4D2/BizzyMoon) repo, running on the same
SirPlease zonemod v1.0.0 base as the rest of the fleet. 60-tick, up to 31 players.
Replaced Flat's Hole and Bizzy's ZoneMod on 2026-11-25.

Placement: the prod host, game port **27017/udp**.

## How it is built: an upstream overlay

Unlike the other servers, Moonland's gameplay content does **not** live in this
repo. BizzyMoon is the source of truth, pinned to an exact commit in
[`deploy.env`](deploy.env). This directory holds only what Bizzymod changes on
top of it.

| Layer (bottom to top) | Source |
|---|---|
| Current L4D2 game files + Valve's stock cfgs | an up-to-date install on the host (`--base-game`) + [`stock-cfg.txt`](../../.deploy/moonland/stock-cfg.txt) |
| Metamod, SourceMod, l4dtoolz, tickrate_enabler, stripper, fixes | zonemod release `ZONEMOD_RELEASE_TAG` |
| Moon's modes, plugins, cfgs, admins | BizzyMoon @ `UPSTREAM_REF` |
| Local overrides (this dir, token-replaced) | `servers/moonland/` |
| Settings | `deploy.env`: hostname rewrite, restart grace, disabled plugins, guaranteed admins |

Local overrides in this directory:

- `cfg/server.cfg` — replaces zonemod's stock file (no default hostname, no public
  default RCON password). Moonland leaves RCON disabled, as BizzyMoon does.
- `addons/sourcemod/configs/databases.cfg` — SourceBans + `bizzymod_stats`, tokenized
  exactly like Dugout's.
- `bizzymod_stats` plugin, gamedata, translations and config — Moonland reports to
  the fleet stats pipeline instead of BizzyMoon's legacy `l4d_stats` (disabled).

The build also blanks any literal `rcon_password` value found in upstream cfgs,
rewrites upstream's hardcoded hostname to `SERVER_NAME`, and guarantees the admins
listed in `ENSURE_ADMINS` stay present.

## Deploying (manual only)

There is no workflow for Moonland. On the game host, as root, from a checkout of
this repo:

```sh
export SERVER_IP=<host address>
export SOURCEBANS_DB=… SOURCEBANS_DB_IP=… SOURCEBANS_PORT=… SOURCEBANS_USER=… SOURCEBANS_PASS=…
export L4DSTATS_DB_IP=… L4DSTATS_PORT=… L4DSTATS_USER=… L4DSTATS_PASS=…

# 1. Assemble into a scratch dir and review (no service changes):
.deploy/moonland/build.sh --base-game /home/<user>/Steam/steamapps/common/l4d2 --stage-only /root/moonland-stage

# 2. Build for real (stops the server, rebuilds, installs the init script,
#    cron autostart and firewall rule if missing, starts the server):
.deploy/moonland/build.sh --base-game /home/<user>/Steam/steamapps/common/l4d2
```

`--base-game` should be an install already on the current game build (any other
server's l4d2 directory works). Rebuilds preserve the server's `bizzymod_stats`
identity key, SourceMod sqlite data and logs.

To take a newer BizzyMoon, bump `UPSTREAM_REF`, run a `--stage-only` build and
check its SourceMod error log after the first start.

## Things to know

- **Boot config is `exec.cfg`, not `server1.cfg`.** BizzyMoon's `server1.cfg` only
  sets `servercfgfile exec.cfg`, so booting with it skips every config (hostname
  included) until the second map.
- **Valve's stock loose cfgs are required.** `valve.rc` ends with `stuffcmds`,
  which runs the `+map`/`+servercfgfile` launch args. Without it srcds idles with
  no map and never answers queries.
- **A fresh build will not be byte-identical to a running server.** At runtime
  SourceMod's updater refreshes core gamedata, SourceBans++ moves `basebans.smx`
  to `plugins/disabled/`, and plugins write their own `cfg/sourcemod/*.cfg`.
- **BizzyMoon cannot be cloned on Windows** (`cfg/con.cfg` is a reserved device
  name). Inspect it on Linux.
- **Known upstream gaps** (plugins added to BizzyMoon without their dependencies;
  they fail to load and are otherwise harmless):
  - `l4d_sm_respawn` — gamedata `l4drespawn.txt` not in the repo
  - `l4d2_navigation_fixes`, `l4d2_riot_penetration` — gamedata `l4d2_nav_loot.txt` not in the repo
  - `sacrifice_finale_revamp` — built against the old `srcscramble.ext` name (now `sourcescramble.ext`)
  - `l4dunreservelobby`, `l4d_instarespawnfix` — need the retired Left 4 Downtown extension
  - `HealthExpolitFixes` — L4D1 only
