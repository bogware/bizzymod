# INSTALL.md — Deploy your own Bizzymod

A start-to-finish guide to standing up your **own** Bizzymod Left 4 Dead 2 server
from this repository. It is written to be followed **deterministically** — by a
human operator or by an autonomous agent.

By the end you will have a **hardened Ubuntu box** running one or more L4D2 servers,
each assembled from a `servers/<name>/` overlay in this repo, optionally reporting
to MySQL stats + SourceBans databases.

---

## 0. How to read this guide (for agents)

> [!IMPORTANT]
> **Operating contract.** Follow these rules throughout:
> - **Verify every gate.** Each phase ends with a ✅ *Verify* block. Do not proceed
>   until its checks pass. If a check fails, stop and resolve it — later phases assume
>   the earlier ones succeeded.
> - **Idempotent by design.** [`bootstrap.sh`](.deploy/bootstrap.sh) and the overlay
>   steps are safe to re-run. Prefer re-running a phase over hand-patching drift.
> - **Secrets stay out of band.** Never commit, echo, or paste real passwords/RCON/DB
>   credentials into the repo, chat, or command lines that get logged. Pass them via
>   environment, a protected `.env` on the box, or GitHub Actions secrets.
> - **Line endings are LF.** `.gitattributes` enforces it. CRLF reaching the box
>   breaks shell scripts (`bad interpreter: /bin/sh^M`). If you edit on Windows, keep
>   `core.autocrlf` from rewriting shipped files.
> - **Don't guess Valve.** The base-game install (Phase 2) **cannot** be done
>   anonymously — it needs a Steam account that owns L4D2. There is no workaround.
> - **Placeholders.** `<LIKE_THIS>` means *you supply the value*. `#{LikeThis}#` is a
>   deploy **token** replaced automatically (see §Token reference).

---

## 1. Prerequisites

Resolve this checklist before starting.

| Requirement | Detail |
|---|---|
| **A box** | Ubuntu **22.04 or 24.04 LTS**, root/sudo, public IPv4. ≥2 GB RAM for one server; ~3.8 GB comfortably runs two. ~6 GB free disk for the base game. |
| **A non-root admin user** | SSH logs in as this user; `bootstrap.sh` disables root SSH. Create with `adduser youradmin && usermod -aG sudo youradmin`. |
| **A Steam account that owns L4D2** | Required for the base-game install (Valve blocks anonymous L4D2 dedicated-server installs). |
| **This repo, on the box** | `git clone https://github.com/bogware/bizzymod.git` |
| **(Optional) MySQL** | Only if you want the `bizzymod_stats` telemetry and/or SourceBans++ bans. A reachable MySQL 5.7+/8.0 server and a DB user. |
| **(Optional) SourcePawn compiler** | Only if you will **modify** a plugin's `.sp`. The repo ships prebuilt `.smx`; a plain deploy needs no compiler. |

### Decisions to make up front

| Decision | Options | Notes |
|---|---|---|
| **Which mode(s)?** | `bizzymod` (realism-versus, matchmode), `campaign` (coop Expert), `vanilla` (pub versus) | Each is a `servers/<name>/` overlay. Start with one. |
| **zonemod base?** | on / off | Set by each server's `deploy.env` (`APPLY_ZONEMOD_OVERLAY`). Versus modes need it; it supplies `confoglcompmod`. |
| **Stats?** | on / off | Needs MySQL. Omit to run without telemetry. |
| **SourceBans?** | on / off | Needs MySQL + a web SourceBans install. Omit for local/admin-file bans only. |
| **One box or dev+prod?** | — | The same overlay deploys to either; identity differs by token values. |

---

## 2. Phase 1 — Provision + harden the box

[`bootstrap.sh`](.deploy/bootstrap.sh) is a one-shot, **idempotent** installer that
turns a bare Ubuntu host into a locked-down game host. Run it **as root**, from the
repo root, naming your admin user:

```sh
sudo SSH_USER=youradmin bash .deploy/bootstrap.sh
```

<details>
<summary>What it does, in order (14 phases)</summary>

1. Preflight (root/OS checks, knob parsing, timestamped backups under `/root`)
2. System update + base packages
3. SSH **admin user** prep (adds to `sudo`, sane `.ssh` perms)
4. **SSH daemon hardening** (`PermitRootLogin no`, `MaxAuthTries 3`, `AllowUsers`, strong crypto; validated with `sshd -t` before reload so you can't lock yourself out)
5. **UFW** firewall (default-deny inbound; allow SSH rate-limited + UDP game port)
6. **GeoIP blocklist** (ipset + UFW splice + weekly refresh timer)
7. **fail2ban** (aggressive sshd jail + recidive)
8. **Unattended security upgrades** (auto-patch; **no** auto-reboot)
9. Kernel / **sysctl** hardening
10. i386 multiarch + 32-bit L4D2 runtime libs
11. `srcds` user + home
12. **steamcmd** install (as the srcds user)
13. Initial L4D2 install (Phase 2 below — skippable here)
14. srcds launch wrapper + **systemd** unit + env file + logrotate

</details>

**Knobs** (all optional env vars; defaults shown):

| Knob | Default | Purpose |
|---|---|---|
| `SRCDS_USER` | `campaign` | Unix user that runs `srcds_run`. Use one per server (`bizzymod`, `flatshole`, …). |
| `SRCDS_PORT` | `27015` | UDP game port. |
| `SSH_USER` | `$(logname)` | Admin user allowed to SSH. **Required** if it can't be inferred. |
| `SSH_PORT` | `22` | Change for security-by-obscurity if desired. |
| `SKIP_L4D2_INSTALL` | `0` | `1` = skip the base-game download in Phase 2 (do it yourself). |
| `SKIP_GEOIP` | `0` | `1` = don't install the GeoIP blocklist. |
| `GEOBLOCK_GAME_PORT` | `0` | `1` = also geo-block the game port (not just SSH). |

> [!WARNING]
> Bootstrap changes SSH (disables root login, restricts `AllowUsers`, optionally
> moves the port). **Keep your current session open** and confirm you can open a
> **second** SSH session as `youradmin` before closing the first.

### ✅ Verify Phase 1

```sh
sudo ufw status verbose                 # active; default deny in; SSH + game port allowed
sudo systemctl status fail2ban          # active (running)
id campaign                             # (or your SRCDS_USER) exists
ls /home/<SRCDS_USER>/steamcmd/steamcmd.sh   # steamcmd present
systemctl is-enabled bizzymod-campaign  # enabled (not started yet — correct)
```

---

## 3. Phase 2 — Install the base game (Valve-gated, one-time)

> [!IMPORTANT]
> Valve **rejects anonymous** L4D2 dedicated-server installs (`Invalid platform`).
> You must log in with a real Steam account that **owns L4D2**. This is out-of-band
> and done **once per box** — the content deploy never touches the base game.

As the srcds user:

```sh
sudo -u <SRCDS_USER> -H bash -lc '
  cd ~/steamcmd
  ./steamcmd.sh +force_install_dir ~/Steam/steamapps/common/l4d2 \
    +login <STEAM_USER> +app_update 222860 validate +quit
'
```

Enter the password + Steam Guard code when prompted. App `222860` is the L4D2
dedicated server. (If you ran `bootstrap.sh` without `SKIP_L4D2_INSTALL=1` and it
had a logged-in session, this may already be done.)

### ✅ Verify Phase 2

```sh
ls /home/<SRCDS_USER>/Steam/steamapps/common/l4d2/srcds_run       # exists
ls /home/<SRCDS_USER>/Steam/steamapps/common/l4d2/left4dead2/     # game content present
```

---

## 4. Phase 3 — Lay the content overlay

The install directory is `<INSTALL>/left4dead2/` where
`<INSTALL> = /home/<SRCDS_USER>/Steam/steamapps/common/l4d2`. You now stack content
onto it in this order: **zonemod base → (optional plugin compile) → token-replace →
your server overlay on top.**

Check the mode's manifest first — it declares what applies:

```sh
cat servers/<name>/deploy.env     # APPLY_ZONEMOD_OVERLAY, QUARANTINE_*, SOURCEMOD_VERSION
```

### 3a. Lay the zonemod base — *if `APPLY_ZONEMOD_OVERLAY=true`*

Fetch the **zonemod Linux overlay** at the pinned tag (`ZONEMOD_RELEASE_TAG`, e.g.
`v1.0.0`) from [SirPlease/L4D2-Competitive-Rework](https://github.com/SirPlease/L4D2-Competitive-Rework)
and rsync it onto the install. This supplies `confoglcompmod`, the competitive
fixes, and the base config library:

```sh
rsync -a --delete-after zonemod-overlay/  <INSTALL>/left4dead2/
```

> `--delete-after` also wipes stale/bad content already on the target. Skip the
> entire step for modes that set `APPLY_ZONEMOD_OVERLAY=false`.

### 3b. Compile plugins — *only if you changed a `.sp`*

The repo ships prebuilt `.smx`, so a normal deploy **skips this**. To rebuild after
editing `servers/<name>/addons/sourcemod/scripting/*.sp`, use a **SourceMod 1.12**
compiler (match `SOURCEMOD_VERSION` exactly — ABI drift silently corrupts behavior):

```sh
# CI does this via rumblefrog/setup-sp; locally:
SM_COMPILE_ROOT=/path/to/sm-1.12 .deploy/build-plugins.sh servers/<name>
```

### 3c. Token-replace the cfgs

`#{Token}#` placeholders in the overlay's `.cfg` files are substituted from
environment variables. Export the values (see §Token reference), then:

```sh
SERVER_NAME="My Server"  RCON_PASS=…  L4DSTATS_DB_IP=…  (…all tokens…) \
  .deploy/replace-tokens.sh servers/<name>
# add --strict to fail if any referenced token is unset
```

> [!NOTE]
> If you run **without** stats/SourceBans, the DB tokens still need *some* value
> (point them at a dummy/local DB or leave the plugins unloaded). Unresolved
> `#{…}#` left in a cfg will be read literally by the game.

### 3d. Rsync your overlay on top (repo wins)

```sh
rsync -a --exclude deploy.env  servers/<name>/  <INSTALL>/left4dead2/
sudo chown -R <SRCDS_USER>:<SRCDS_USER> <INSTALL>/left4dead2/
```

If the mode sets `QUARANTINE_MATCHMODE=true` (coop) or lists `QUARANTINE_FIXES`,
move those `.smx` into `addons/sourcemod/plugins/disabled/` on the box so they don't
auto-load. Versus modes keep the matchmode plugins **loaded**.

### ✅ Verify Phase 3

```sh
ls <INSTALL>/left4dead2/cfg/server1.cfg                          # your overlay landed
grep -R '#{' <INSTALL>/left4dead2/cfg/ | grep -v '//'            # should be EMPTY (no leftover tokens)
file <INSTALL>/left4dead2/addons/sourcemod/plugins/optional/bizzymod/*.smx  # SourcePawn binaries
```

---

## 5. Phase 4 — Databases *(optional)*

Skip entirely if you're running without stats or SourceBans.

### Stats (`bizzymod_stats`)

Create the database and apply the **15 versioned migrations** under
[`.deploy/bizzymod_stats_schema/`](.deploy/bizzymod_stats_schema/):

```sh
mysql -h <DB_HOST> -u <USER> -p -e \
  "CREATE DATABASE bizzymod_stats CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

cd .deploy/bizzymod_stats_schema
pip install -r scripts/requirements.txt
python3 scripts/migrate.py           # applies 001…015 in order, idempotently
```

Point the `l4dstats_*` tokens at this DB. Each install self-assigns a `server_id`
from a random `addons/sourcemod/data/bizzymod_stats.server_key` on first boot —
**never copy another install's keyfile** (it would merge two servers' stats).

### SourceBans++

Stand up the SourceBans web app + DB separately, then set the `SourceBans_*` tokens
and `SB_ServerID` (the non-zero id from the `bans_servers` table — `sbpp_comms`
requires it). Admins without a DB can use `addons/sourcemod/configs/admins_simple.ini`.

### ✅ Verify Phase 4

```sh
mysql -h <DB_HOST> -u <USER> -p bizzymod_stats -e "SHOW TABLES;"   # schema present
```

---

## 6. Phase 5 — Launch & verify

Start the service installed by bootstrap (or the mode's init script if you use the
`/etc/init.d/srcds<Name>` pattern):

```sh
sudo systemctl start bizzymod-campaign          # systemd unit from bootstrap
sudo systemctl status bizzymod-campaign         # active (running)
sudo journalctl -u bizzymod-campaign -f         # live logs
```

### ✅ Verify Phase 5 — the server is really up

```sh
ps -u <SRCDS_USER> -o pid,cmd | grep srcds_linux           # process alive
ss -lntup | grep ':<SRCDS_PORT>'                           # listening (UDP+TCP)
```

Then, in-game or via RCON:

- **Connect:** `connect <PUBLIC_IP>:<SRCDS_PORT>` — you reach the server.
- **SourceMod loaded:** `sm plugins list` — your plugins show as *running*, no load errors.
- **Matchmode (versus):** `!match` opens the vote menu; pick a config → it applies.
- **Stats (if enabled):** play a round, then confirm rows land in `bizzymod_stats`.
- **Admins:** an admin in `admins_simple.ini`/SourceBans has their flags.

---

## Token reference

`replace-tokens.sh` substitutes each `#{Token}#` from the named environment
variable ([`.deploy/replace-tokens.sh`](.deploy/replace-tokens.sh)):

| Token (`#{…}#`) | Env var | Meaning |
|---|---|---|
| `#{Server_Name}#` | `SERVER_NAME` | Public hostname |
| `#{RCON_Pass}#` | `RCON_PASS` | Server RCON password |
| `#{l4dstats_DB}#` | `L4DSTATS_DB` | Stats database name |
| `#{l4dstats_DB_IP}#` | `L4DSTATS_DB_IP` | Stats DB host |
| `#{l4dstats_Port}#` | `L4DSTATS_PORT` | Stats DB port |
| `#{l4dstats_User}#` | `L4DSTATS_USER` | Stats DB user |
| `#{l4dstats_Pass}#` | `L4DSTATS_PASS` | Stats DB password |
| `#{SourceBans_DB}#` | `SOURCEBANS_DB` | SourceBans DB name |
| `#{SourceBans_DB_IP}#` | `SOURCEBANS_DB_IP` | SourceBans DB host |
| `#{SourceBans_Port}#` | `SOURCEBANS_PORT` | SourceBans DB port |
| `#{SourceBans_User}#` | `SOURCEBANS_USER` | SourceBans DB user |
| `#{SourceBans_Pass}#` | `SOURCEBANS_PASS` | SourceBans DB password |
| `#{SB_ServerID}#` | `SB_SERVERID` | This server's SourceBans id (non-zero) |
| `#{userName}#` | `SRCDS_USER` | srcds unix user |
| `#{RemoteTargetFolder}#` | `REMOTE_TARGET_FOLDER` | Install path |
| `#{initPath}#` | `INIT_PATH` | init script path |

> Passwords are **never** stored in the repo cfgs — only the tokens are. Supply the
> values at deploy time (env, protected `.env`, or GitHub Actions secrets).

---

## `deploy.env` reference

Each `servers/<name>/deploy.env` declares that mode's build/deploy knobs (shell syntax):

| Key | Meaning |
|---|---|
| `APPLY_ZONEMOD_OVERLAY` | Lay the zonemod base first? (`true` for versus) |
| `ZONEMOD_RELEASE_TAG` | Which zonemod release to lay (e.g. `v1.0.0`) |
| `QUARANTINE_MATCHMODE` | Move `confoglcompmod`/`match_vote`/`reservedslots` into `disabled/`? (`true` for coop) |
| `QUARANTINE_FIXES` | Extra `.smx` to quarantine (space-separated) |
| `SOURCEMOD_VERSION` | SourceMod line to compile against — **must** match the runtime |

---

## Automating it (GitHub Actions)

The [`.github/workflows/`](.github/workflows/) encode this same flow as an
Environment-scoped pipeline (`deploy` · `diagnose` · `migrate-stats`), run manually
with `server` + `environment` inputs on a self-hosted Linux runner. The complete
secret/variable matrix for wiring CI lives in **[`DEPLOY.md`](DEPLOY.md)**. Until
those Environments are configured, the manual overlay path above is canonical.

---

## Troubleshooting

| Symptom | Likely cause → fix |
|---|---|
| `bad interpreter: /bin/sh^M` | CRLF line endings reached the box → ensure LF; `sed -i 's/\r$//'` the shipped shell/cfg files. |
| Base install: `Invalid platform` | Anonymous steamcmd login → use a Steam account that **owns** L4D2 (Phase 2). |
| Plugins load but behave wrong | SourceMod ABI drift → `SOURCEMOD_VERSION` must match what the runtime ships; recompile. |
| `sbpp_comms` won't register | `SB_ServerID` is `0`/unset → set the non-zero id from the `bans_servers` table. |
| Server won't appear / connect | UFW not allowing the UDP game port, or srcds not listening → re-check Phase 1 & 5 verify blocks. |
| Leftover `#{…}#` in a live cfg | A token env var was unset at replace time → export it and re-run `replace-tokens.sh --strict`. |
| Stats from two servers merge | A `bizzymod_stats.server_key` was copied between installs → delete it on one; it self-reassigns on boot. |
| Locked out after SSH hardening | You closed your session before testing `youradmin` → use the console; backups are under `/root/bizzymod-bootstrap-backups/`. |

---

## Make it your own

1. **Fork a server dir:** copy `servers/vanilla/` → `servers/<yourmode>/` for its own
   git lineage (copy-and-adjust — never refactor shared plugins into a common tree).
2. **Set identity:** edit `cfg/server1.cfg`, the `host`/`motd` text files, and the
   matchmaking `sv_search_key`.
3. **Tune the manifest:** write `servers/<yourmode>/deploy.env`.
4. **Deploy** with Phases 3–5 above, pointing them at `servers/<yourmode>/`.

See **[`CLAUDE.md`](CLAUDE.md)** for the full set of repo conventions and gotchas.
