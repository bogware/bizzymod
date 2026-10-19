# DEPLOY.md — deploying the Bizzymod servers

Everything ships through **GitHub Actions**, on a **self-hosted Linux runner**,
**manually** (no push ever auto-deploys). One workflow deploys any server to any
environment; you pick both when you run it.

```
Actions ▸ Deploy ▸ Run workflow ▸ server=campaign  environment=dev
# or:
gh workflow run deploy.yml -f server=campaign -f environment=dev
```

---

## Status: CI is not wired yet — **manual deploy is canonical** (2026-10)

The GitHub Actions workflows described below are the *intended* automated path,
but they are **not operational today**: the per-target GitHub Environments
(`<server>-<environment>`, e.g. `bizzymod-prod`) and their secrets/vars **do not
exist**, and no monorepo-era deploy has ever run through CI (the last Actions
deploy was the pre-monorepo push model in mid-2026). A dispatched run now fails
fast at each workflow's **Preflight** guard.

Every server in the fleet today was deployed **by hand** — tar the
`servers/<server>/` overlay, `pscp`/`rsync` it to the box, and run an on-box
overlay script onto the zonemod base. So the **GitHub configuration** section
below is a **spec for wiring CI later**, not a description of what's live. Until
someone creates those Environments, the manual path (and the **Dev box fleet**
notes) are the source of truth.

---

## The model

- **server** = a game mode under `servers/<server>/` (self-contained overlay).
  Wired: `campaign` (coop), `vanilla` (Flat's Hole versus), `bizzymod` (Bizzy's
  Dugout realism-versus). `competitive` is still an empty scaffold.
- **environment** = `dev` or `prod`. Both are real, public servers; players don't
  notice which is which.
- The job binds to the **GitHub Environment `<server>-<environment>`** (e.g.
  `campaign-prod`, `campaign-dev`), which supplies that target's SSH/RCON/identity
  secrets and vars. Same secret *names* everywhere; the Environment scopes the
  *values*.
- **DB creds are shared** across every server and environment (repo-level
  secrets/vars) — all servers report to the same stats + SourceBans databases.
- Each server's `servers/<server>/deploy.env` declares its build/deploy knobs
  (zonemod overlay? matchmode quarantine? which fixes to disable).

A deploy: compile the server's plugins → (optionally) lay the zonemod overlay with
`--delete-after` (which also wipes any stale/bad content already on the target) →
token-replace the cfgs → rsync `servers/<server>/` on top → chmod → restart →
verify `srcds_run` is alive.

---

## The targets

Campaign is the template below (dev + prod); Flat's Hole and Bizzy's Dugout follow
it, sharing the prod box under their own users — see the two subsections that follow.

| | **campaign-prod** | **campaign-dev** |
|---|---|---|
| SSH host | `<PROD_HOST>` | `<DEV_HOST>` |
| SSH port | `1989` | `1989` |
| SSH user | `root` | `root` |
| Install (`REMOTE_TARGET_FOLDER`) | `/home/campaign/Steam/steamapps/common/l4d2/left4dead2` | `/home/campaign/Steam/steamapps/common/l4d2/left4dead2` |
| srcds user (`SRCDS_USER`) | `campaign` | `campaign` |
| srcds port | `27016` | `27016` |

`prod` is the box we harden first. **Caution — `campaign-dev` is stale:** on
2026-10-12 the `/home/campaign` install on the dev box (`<DEV_HOST>`) was
repurposed into **Bizzy's Secret Sauce** (the `vanilla` overlay). There is no
campaign-coop server on dev anymore, and a `campaign-dev` deploy to the path
above would **clobber Secret Sauce**. Dev is deployed manually — see the **Dev
box fleet** section below.

### Flat's Hole (vanilla versus) — `vanilla-prod`

Shares the campaign **prod** box, under its own user:

| | **vanilla-prod** |
|---|---|
| SSH host / port / user | `<PROD_HOST>` / `1989` / `root` (same as campaign-prod) |
| Install (`REMOTE_TARGET_FOLDER`) | `/home/flatshole/Steam/steamapps/common/l4d2/left4dead2` |
| srcds user (`SRCDS_USER`) | `flatshole` |
| init (`INIT_PATH`) | `/etc/init.d/srcdsFlatsHole` |
| srcds port | `27017` |
| `SERVER_NAME` | `Flat's Hole` |
| `RCON_PASS` | same as campaign (reused) |
| `SB_SERVERID` | `6` (prod) — sbpp_comms needs a valid, non-zero SourceBans server id |

So the `vanilla-prod` Environment reuses campaign-prod's `SSH_HOST` / `SSH_PASSWORD`
/ `SUDO_PASSWORD` / `RCON_PASS`, with `REMOTE_TARGET_FOLDER`, `SRCDS_USER`,
`INIT_PATH`, `SERVER_NAME` (and `SSH_PORT`/`SSH_USER`) set to the values above.

### Bizzy's Dugout (bizzymod realism-versus) — `bizzymod-prod`

The **main mode** — the competitive realism-versus server (full confoglcompmod
matchmode, zonemod v1.0.0 base + bizzymod overlay). Shares the campaign **prod**
box, under its own user:

| | **bizzymod-prod** |
|---|---|
| SSH host / port / user | `<PROD_HOST>` / `1989` / `root` (same as campaign-prod) |
| Install (`REMOTE_TARGET_FOLDER`) | `/home/bizzymod/Steam/steamapps/common/l4d2/left4dead2` |
| srcds user (`SRCDS_USER`) | `bizzymod` |
| init (`INIT_PATH`) | `/etc/init.d/srcdsBizzymod` |
| srcds port | `27015` |
| `SERVER_NAME` | `Bizzy's Dugout` |
| `RCON_PASS` | its own (or reuse campaign's) |
| `SB_SERVERID` | `1` (prod) / `3` (dev) — sbpp_comms needs a valid, non-zero SourceBans server id |

So the `bizzymod-prod` Environment reuses campaign-prod's `SSH_HOST` /
`SSH_PASSWORD` / `SUDO_PASSWORD`, with `REMOTE_TARGET_FOLDER`, `SRCDS_USER`,
`INIT_PATH`, `SERVER_NAME`, `RCON_PASS` (and `SSH_PORT`/`SSH_USER`) set to the
values above. Unlike campaign, `deploy.env` here keeps matchmode **enabled**
(`QUARANTINE_MATCHMODE=false`).

> Note: this server owns `sv_search_key "bizzymod"`; campaign was moved to
> `sv_search_key "bizzymod-campaign"` so bizzymod lobbies route here.

### Dev box fleet (`<DEV_HOST>`) — manual deploy, 2026-10-12

The dev box was repurposed into its **own live 2-server fleet** (the CI `deploy.yml`
path has no dev Environments yet, so these were deployed **manually**: tar the repo
overlay → `pscp` to `/root` → on-box overlay script onto the existing zonemod base).
It has **3.8 GB RAM / no swap**, so it runs **two** servers, not three.

| | **Bizzy's Playhouse** | **Bizzy's Secret Sauce** |
|---|---|---|
| overlay | `servers/bizzymod` (= Dugout) | `servers/vanilla` (= Flat's Hole) |
| srcds user / init | `bizzymod` / `srcdsBizzymod` | `campaign` / `srcdsCampaign` (reused) |
| srcds port | `27015` | `27016` |
| mode | versus (matchmode on) | vanilla |
| **stats** | **ON** — self-registered `server_id=517` in the shared DB, distinct from Dugout (246) / Campaign (218) | **OFF** — `bizzymod_stats` load line commented in `flatshole.cfg` |

`server_id` is auto-assigned from the random per-install
`addons/sourcemod/data/bizzymod_stats.server_key` (deleting it before first boot
forces a fresh id — never copy another install's keyfile). Secret Sauce is a
placeholder to customize later; when it diverges from vanilla, fork
`servers/vanilla` → `servers/secretsauce` for its **own git lineage**.

**Retired `_legacy`:** `bizzymoon` ("Moonmod") — stopped, de-croned, init →
`srcdsBizzymoon.legacy`, home → `/home/bizzymoon_legacy`. The old `campaign`
("Part Deux") identity was overwritten to become Secret Sauce. Rollback snapshots:
`/home/_legacy_snapshots/2026-10-12/`.

---

## GitHub configuration

### Per-target — GitHub **Environments** (`Settings ▸ Environments`)

Create `campaign-dev` and `campaign-prod`. Each gets:

**Environment secrets**

| Secret | Meaning |
|---|---|
| `SSH_HOST` | game-server IP |
| `SSH_PASSWORD` | SSH password for `SSH_USER` |
| `SUDO_PASSWORD` | sudo password on the box (fed to `sudo -S` over stdin) |
| `RCON_PASS` | server RCON password (token-replaced into cfgs) |

**Environment variables**

| Var | Example |
|---|---|
| `SSH_PORT` | `1989` |
| `SSH_USER` | `root` |
| `REMOTE_TARGET_FOLDER` | `/home/campaign/Steam/steamapps/common/l4d2/left4dead2` |
| `SRCDS_USER` | `campaign` |
| `INIT_PATH` | init script that start/stops srcds, e.g. `/etc/init.d/srcdsCampaign` |
| `SERVER_NAME` | hostname, e.g. `Bizzymod Campaign` (prod) / `Bizzymod Campaign [DEV]` (dev) |
| `SB_SERVERID` | this env's SourceBans server id (from the `bans_servers` table) — sbpp_comms requires a valid, non-zero id. e.g. bizzymod-prod=`1`, bizzymod-dev=`3` |

> Host banner / MOTD are **literal `.txt` files** in each overlay
> (`servers/<server>/{host,motd}.txt`, pointing at `bizzymod.com`), not deploy
> tokens — there is no `HOST_BANNER`/`HOST_MOTD` var to set.

### Shared — **repo-level** (`Settings ▸ Secrets and variables ▸ Actions`)

**Repo secrets**

| Secret | Meaning |
|---|---|
| `L4DSTATS_PASS` | MySQL password (bizzymod-stats + legacy l4dstats DBs) |
| `SOURCEBANS_PASS` | MySQL password (SourceBans++ DB) |
| `STEAM_USER` / `STEAM_PASS` | *(optional)* Steam account owning L4D2, only if you enable the per-deploy `steamcmd validate` |

**Repo variables**

| Var | Meaning |
|---|---|
| `L4DSTATS_DB`, `L4DSTATS_DB_IP`, `L4DSTATS_PORT`, `L4DSTATS_USER` | stats DB connection |
| `SOURCEBANS_DB`, `SOURCEBANS_DB_IP`, `SOURCEBANS_PORT`, `SOURCEBANS_USER` | SourceBans DB connection |

> Token placeholders `#{TokenName}#` in the cfgs are replaced from these at deploy
> time (see `.deploy/replace-tokens.sh`). Never hardcode the real values into cfgs.

---

## The self-hosted runner

- Registered under the **bogware** org with labels **`self-hosted`** and **`Linux`**;
  the workflows target `runs-on: [self-hosted, Linux]`.
- Runs **build + deploy** — it is the box with SSH reach to both game servers.
- Must have these tools preinstalled (the workflow checks and fails clearly if not;
  it does **not** try to `sudo apt-get` them, since the runner may lack passwordless
  sudo):

  ```sh
  sudo apt-get install -y sshpass rsync curl tar openssh-client
  ```

---

## Base game install (one-time, out-of-band)

Valve **blocks anonymous L4D2 dedicated-server installs** ("Invalid platform"), so
the base game is installed once per box with a real Steam account that owns L4D2 —
**not** by the deploy. The per-deploy `steamcmd app_update … validate` step is
skipped unless you set `STEAM_USER`/`STEAM_PASS` and run with
`skip_steam_update=false`. See `guide/` for standing up a fresh box.

---

## Adding a new server (e.g. competitive)

1. Populate `servers/<name>/` as a self-contained overlay (mirror `servers/campaign/`).
2. Write `servers/<name>/deploy.env` (zonemod on/off, matchmode quarantine on/off,
   fixes to disable, SourceMod line).
3. Add `<name>` to the `server` input options in `.github/workflows/deploy.yml`
   (and `diagnose.yml` / `migrate-stats.yml`).
4. Create Environments `<name>-dev` and `<name>-prod` with the per-target
   secrets/vars above.

---

## Sibling workflows

- **Diagnose server** (`diagnose.yml`) — same `server`/`environment` inputs; dumps
  recent SourceMod errors, checks gamedata/plugin loads, verifies the stats DB.
- **Migrate stats DB** (`migrate-stats.yml`) — applies the bizzymod-stats schema +
  legacy import against the shared stats DB.

Both are manual, self-hosted, and Environment-scoped exactly like the deploy.
