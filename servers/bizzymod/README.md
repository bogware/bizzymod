# servers/bizzymod — Bizzy's Dugout (bizzymod realism-versus)

The **main mode**: bizzymod's competitive **realism-versus** server. This is the
faithful recreation of the long-running legacy "Bizzy's Playhouse" confogl build,
rebuilt on the **modern SirPlease zonemod v1.0.0** framework.

## What it is

- **mp_gamemode `mutation12` (Realism Versus)**, 4v4, 100-tick. Config identity
  "bizzymod 0.8".
- Runs the **full confoglcompmod matchmode system** — any player can `!match` to
  vote a mode. ~50 configs are selectable: the **bizzymod family** (bizzymod,
  numbersmod, barrymod, surfmod, spacemod, thundermod, acv, zonereal, kneemod,
  bobbymod, seltzermod, busmod, bananamod, heizemod, flatmod, onemod, powermod,
  invokemod, deadmanX, hardcoremod, pissmod) **plus** every zonemod config the
  overlay ships (zonemod, zoneretro, zm/eq/nextmod/amrv/zh NvN variants, neomod,
  apex, acemodrv, pmelite, deadman, zonehunters). Default: **numbersmod**.
- **Identity:** `sv_search_key "bizzymod"` (THE bizzymod key — campaign moved to
  `bizzymod-campaign`); Steam group `38693222`, public / non-exclusive.

## How it's built (deploy)

`deploy.env`: `APPLY_ZONEMOD_OVERLAY=true`, `ZONEMOD_RELEASE_TAG=v1.0.0`,
`QUARANTINE_MATCHMODE=false` (matchmode stays **on** — opposite of campaign),
`QUARANTINE_FIXES=""`, `SOURCEMOD_VERSION=1.12.x`.

The deploy lays **zonemod v1.0.0** down first (it supplies the confoglcompmod
framework, readyup, ~25 configs, and the fixes/optional competitive plugin set),
then rsyncs this overlay on top. This overlay carries only the **bizzymod-specific
delta** that zonemod lacks:

- **24 cfgogl configs** (`cfg/cfgogl/`) — the bizzymod-family rulesets.
- **36 plugins** — the bizzymod-branded set (`plugins/bizzymod/`: bizzykits,
  l4d2_mix, l4d2scores, JockeyPounce, SpecListener, vscript_replacer, ...), 3 fixes
  zonemod lacks (`plugins/fixes/`), and the anticheat stack (`plugins/anticheat/`:
  SourceBans++ + lilac + noghostcheat).
- **`plugins/optional/bizzymod/bizzymod_stats.smx`** — the modern MySQL stats
  plugin (own `server_id`, shared DB; compiled by the workflow from
  `scripting/bizzymod_stats/`). Replaces the legacy l4d_stats ranking.
- **gamedata** (11), **extensions** (SteamWorks, socket), the **bizzymod stripper
  tree** (`cfg/stripper/bizzymod/`, 138 maps), and the **vscripts**
  (`scripts/vscripts/`, incl. `bizzymodRealism.nut` — the realism-versus mode is a
  `vscript_replacer` swap of `mutation12` → `bizzymodRealism`).
- A merged **`matchmodes.txt`** (the full vote menu above).

## Box

Runs on the campaign **prod** box under its own user:

| | |
|---|---|
| host / port | `<PROD_HOST>` : `27015` |
| srcds user | `bizzymod` |
| install | `/home/bizzymod/Steam/steamapps/common/l4d2/left4dead2` |
| init | `/etc/init.d/srcdsBizzymod` |

Deploy: `gh workflow run deploy.yml -f server=bizzymod -f environment=prod`
(requires the `bizzymod-prod` GitHub Environment — see `DEPLOY.md`).

## Stats & bans (shared)

Same MySQL databases as campaign / Flat's Hole: `bizzymod_stats` (this server gets
its own `server_id`) and SourceBans++ (`bans` prefix, `AutoAddServer` registers a
distinct server row). Creds are the shared repo-level secrets, token-replaced into
`databases.cfg` at deploy — never committed.
