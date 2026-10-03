# servers/vanilla — "Flat's Hole" (public vanilla VERSUS)

A public, vanilla Left 4 Dead 2 **Versus** server. Same zonemod base as campaign
(for its stability/bug/crash fixes + anticheat), but **stripped to vanilla**: no
gameplay plugins, matchmode quarantined, and every gameplay-changing fix disabled.
Valve versus, untouched — no team shuffling.

## What runs
- **Kept:** zonemod's pure crash/exploit/netcode/map/vote fixes (auto-load), base
  SourceMod admin plugins, `anticheat/` (SourceBans++ `sbpp_*`, `lilac`,
  `l4d2_noghostcheat`), and **bizzymod-stats** + `sm_RestartEmpty` (loaded by
  `cfg/flatshole.cfg`).
- **Dropped:** every bizzymod gameplay plugin (manual director, spawn props, weapon
  spawn, SuperVersus, gear transfer, explosive cars, mix, l4d2scores, Survivor_Legs)
  and 26 gameplay-changing zonemod fixes (tongue / melee / shove / stagger / hitbox /
  jockey / charger / spit / team-shuffle / bequiet / …) — see `deploy.env`
  `QUARANTINE_FIXES`.

## Where it runs
- **prod:** `<PROD_HOST>:27017`, user `flatshole`, install
  `/home/flatshole/Steam/steamapps/common/l4d2/left4dead2`, init
  `/etc/init.d/srcdsFlatsHole`. Same physical box as campaign (`:27016`, user
  `campaign`).

## Identity
- Hostname `Flat's Hole`; `mp_gamemode versus`; Steam group `38693222` (shared,
  public / non-exclusive); distinct `sv_search_key "flatshole"`.
- Shares the campaign stats + SourceBans DBs; registers as its **own** SourceBans
  server (`AutoAddServer 1`, `ServerID 0`). Reuses campaign's RCON.

## Deploy
`gh workflow run deploy.yml -f server=vanilla -f environment=prod` — once the
`vanilla-prod` GitHub Environment is created (see `DEPLOY.md`).
