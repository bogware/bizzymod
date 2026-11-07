# servers/zonemod — Bizzy's ZoneMod

**Stock (latest) SirPlease zonemod + a thin Bizzymod essentials layer.**

This server runs zonemod exactly as shipped — the full `confoglcompmod` matchmode
(players `!match` to vote among zonemod's own config library), all competitive
fixes, nothing gameplay-altering added — plus only the Bizzymod essentials:

- **`bizzymod_stats`** — per-round/-player telemetry to the shared MySQL stats DB (its own `server_id`).
- **`lilac`** + **`l4d2_noghostcheat`** — anticheat.
- **SourceBans++** (`sbpp_*`) — networked bans/comms (shared SourceBans DB).
- **our admins** — `admins_simple.ini` (the fleet's canonical roster).

## Key difference from the rest of the fleet

Every other server pins the zonemod **`v1.0.0` release**. Bizzy's ZoneMod tracks the
**latest zonemod from `master`**, pinned to a specific commit in
[`deploy.env`](deploy.env) (`ZONEMOD_REF`) for reproducibility — bump it and
re-deploy to pull newer zonemod.

## How it boots

- [`cfg/server1.cfg`](cfg/server1.cfg) — identity + 100-tick cvars, and sets
  `confogl_match_execcfg_plugins` to weave [`cfg/bizzyload.cfg`](cfg/bizzyload.cfg)
  into zonemod's match chain.
- [`cfg/bizzyload.cfg`](cfg/bizzyload.cfg) — the **only** Bizzymod divergence: loads
  stats + anticheat in the unlocked window of the match chain (before confoglcompmod's
  load-lock), so they survive the matchmode's `plugins unload_all`.
- The matchmode framework, fixes, and config library all come from the stock zonemod
  base laid down at deploy (`APPLY_ZONEMOD_OVERLAY=true`, `QUARANTINE_MATCHMODE=false`).

See the repo **[INSTALL.md](../../INSTALL.md)** and **[DEPLOY.md](../../DEPLOY.md)**
for the deploy model; this overlay is self-contained like every other `servers/<name>/`.
