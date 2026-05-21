# Bizzymod Campaign — server bring-up & deploy

This is the end-to-end walkthrough for taking a brand-new Ubuntu 24.04 LTS box
all the way to *"deploy from GitHub Actions on every push to `main`"*. It has
three parts:

1. **Part 1 — Provision the server.** A vanilla Ubuntu host gets hardened and
   prepped for L4D2 / Source / steamcmd with one script.
2. **Part 2 — Wire up GitHub Actions.** Add the right secrets and variables so
   the workflow can reach the server.
3. **Part 3 — Run the first deploy.** Push to `main` and watch the workflow
   put zonemod + this repo onto the box and start the service.

A condensed operations runbook lives at the bottom.

---

## Part 1 — Provision the server

### 1.1 Order / spin up Ubuntu 24.04 LTS

Pick a host with a real public IP, at least 1 vCPU + 1 GB RAM per server
instance, and ideally a 3 GHz+ CPU if you want to honor the 100-tick config.
Anywhere reputable works — NFOServers (US), OVH (EU), Hetzner, Vultr, Linode.
Avoid shared "game-panel" hosts; they refuse to install third-party software.

> **Why Ubuntu 24.04?** It's the current LTS and `bootstrap.sh` is tested on
> it. Ubuntu 22.04 also works (same script). 18.04 (what the legacy
> `guide/README.md` mentions) is end-of-life — use it only if you *also* run a
> client on the same box and care about a cosmetic blood-splatter bug.

When the provider asks for a hostname, something like
`l4d2-campaign-01.yourdomain.tld` is fine. Choose a strong root password and
write it down somewhere safe — you'll only use it once.

### 1.2 SSH in and create your admin user

```bash
# From your laptop:
ssh root@<server-ip>

# On the server (as root):
adduser youradmin            # set a long random password — bitwarden / 1password / pwgen
usermod -aG sudo youradmin
# Optional: SSH key now is nice, but the deploy workflow uses password auth.
exit
```

From here on, log in as the admin user:

```bash
ssh youradmin@<server-ip>
```

### 1.3 Clone this repo and run the bootstrap

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<you>/bizzymod-campaign.git
cd bizzymod-campaign

# Single command. The script is idempotent — safe to re-run.
sudo SSH_USER=youradmin bash .deploy/bootstrap.sh
```

**The 15-phase bootstrap, in plain English:**

| Phase | What changes on your box |
| ----- | ------------------------- |
| 0  | Preflight checks (Ubuntu version, your admin user exists, etc.) |
| 1  | `apt update && upgrade`, then installs the toolbox: `ufw`, `fail2ban`, `ipset`, `unattended-upgrades`, `chrony`, `rsync`, etc. |
| 2  | Adds your admin user to `sudo` (no-op if already there) |
| 3  | Drops `/etc/ssh/sshd_config.d/99-bizzymod-hardening.conf`: root login off, `MaxAuthTries=3`, `AllowUsers=youradmin`, strong KEX/ciphers/MACs, login banner. Validates the config and reloads `sshd` — won't lock you out. |
| 4  | UFW: deny-by-default inbound, `limit` your SSH port (rate-limits brute-force at the firewall), allow UDP 27015 (game) |
| 5  | GeoIP blocklist via `ipset` + UFW. Default blocks: CN, RU, IR, KP, BY (state actors) plus VN, IN, BR, UA, NG, RO (high-noise botnets). **Only blocks SSH/admin TCP — not the game port.** Refreshes weekly via a systemd timer. |
| 6  | `fail2ban` with an aggressive `sshd` jail (3 fails in 5 min → 1 hr ban, doubling on each subsequent ban up to a week) plus a `recidive` jail for repeat offenders |
| 7  | `unattended-upgrades`: security patches install automatically, but the box **never auto-reboots** (no surprise mid-match restarts) |
| 8  | Kernel/sysctl hardening: SYN cookies, rp_filter, ICMP redirect drop, `kptr_restrict`, etc. |
| 9  | Enables i386 multiarch + installs the 32-bit libraries `srcds_linux` needs |
| 10 | Creates the `campaign` system user (the unprivileged account `srcds` runs as) |
| 11 | Installs `steamcmd` to `/home/campaign/steamcmd/` |
| 12 | Runs `steamcmd app_update 222860 validate` — **~5 GB download**, takes 5–20 min depending on bandwidth |
| 13 | Drops the `bizzymod-campaign.service` systemd unit, `srcds-launch.sh`, and a default env file. Service is *enabled* but *not started* — the deploy will start it once content is in place. |
| 14 | Logrotate for L4D2 + SourceMod logs (weekly, 8 generations, compressed) |

Reboot once after the first run so kernel updates take effect:

```bash
sudo reboot
```

### 1.4 Verify the server side

After it comes back:

```bash
ssh youradmin@<server-ip>

# Firewall
sudo ufw status verbose

# Fail2ban
sudo fail2ban-client status
sudo fail2ban-client status sshd

# GeoIP
sudo ipset list geoblock | head
sudo systemctl list-timers bizzymod-geoip-update.timer

# Service (should be 'inactive (dead)' for now — deploy will start it)
sudo systemctl status bizzymod-campaign

# Test that the service can launch (will fail until content is deployed, that's expected)
sudo systemctl start bizzymod-campaign
sudo journalctl -u bizzymod-campaign -n 50
sudo systemctl stop bizzymod-campaign
```

Common things to tweak now (all optional):

- **Custom SSH port** — re-run bootstrap with `sudo SSH_USER=youradmin SSH_PORT=2222 bash .deploy/bootstrap.sh`. Update the GitHub `SSH_PORT` variable to match.
- **More / fewer geoblocked countries** — edit `/etc/bizzymod/geoblock.conf` then `sudo systemctl start bizzymod-geoip-update.service`.
- **Also geoblock the game port** — re-run with `GEOBLOCK_GAME_PORT=1`. *Most servers should not do this*; legit players can come from anywhere.
- **Open SourceTV** — `sudo ufw allow 27020/udp` and set the cvars in `server1.cfg`.

---

## Part 2 — Wire up GitHub Actions

The repo's workflow at `.github/workflows/deploy.yml` connects to the server
over SSH (username + password) to do its work.

### 2.1 Create a `production` environment (recommended)

In GitHub: **Settings → Environments → New environment → `production`**.

Optionally enable **Required reviewers** so deploys to prod need a click before
they run. With that on, each push to `main` queues a deploy that waits for you
to approve in the Actions UI.

### 2.2 Add repository variables (non-sensitive)

**Settings → Secrets and variables → Actions → Variables → New variable.**

| Variable | Example | Notes |
| --- | --- | --- |
| `SERVER_NAME` | `Bizzy's Campaign: Part Deux` | shown in the server browser |
| `HOST_BANNER` | `http://bizzymod.com/hostbanner.html` | hostbanner URL |
| `HOST_MOTD` | `http://bizzymod.com/motd.html` | motd URL |
| `L4DSTATS_DB` | `stats` | l4d_stats MySQL database name |
| `L4DSTATS_DB_IP` | `<DB_HOST>` | MySQL host |
| `L4DSTATS_PORT` | `3306` | MySQL port |
| `L4DSTATS_USER` | `steam` | MySQL user |
| `SOURCEBANS_DB` | `sys` | SourceBans++ database |
| `SOURCEBANS_DB_IP` | `<DB_HOST>` | SourceBans++ host |
| `SOURCEBANS_PORT` | `3306` | SourceBans++ port |
| `SOURCEBANS_USER` | `steam` | SourceBans++ user |
| `SRCDS_USER` | `campaign` | unix user from bootstrap (defaults to `campaign`) |
| `REMOTE_TARGET_FOLDER` | `/home/campaign/Steam/steamapps/common/l4d2` | matches `INSTALL_DIR` from bootstrap |
| `INIT_PATH` | `/etc/init.d/srcdsCampaign` | legacy token; safe default — only used as a `#{...}#` substitution in cfg files |
| `SSH_PORT` | `22` | match what bootstrap set |

### 2.3 Add repository secrets (sensitive — masked in logs)

**Settings → Secrets and variables → Actions → Secrets → New repository secret.**

| Secret | Value |
| --- | --- |
| `SSH_HOST` | server's public IP (e.g. `<DEV_HOST>`) |
| `SSH_USER` | your admin user (e.g. `youradmin`) |
| `SSH_PASSWORD` | the password you set in step 1.2 |
| `SUDO_PASSWORD` | same as `SSH_PASSWORD` unless you've configured separate sudo auth |
| `RCON_PASS` | strong random string; this becomes the server's RCON password |
| `L4DSTATS_PASS` | MySQL password for the stats user |
| `SOURCEBANS_PASS` | MySQL password for the SourceBans++ user |

> **Security caveat on password SSH.** Password auth is materially weaker than
> key auth against credential stuffing. The bootstrap mitigates with:
> `MaxAuthTries=3`, `LoginGraceTime=20`, UFW rate-limit, fail2ban
> (3-fails-in-5min → 1h ban → doubles each repeat → 1 week max), and GeoIP
> blocking against the highest-noise countries. Even with all that, please use
> a **long random** password (24+ chars, mixed). When you're ready, switching
> to key auth is ~10 lines in `deploy.yml`: replace `sshpass -e ssh` with
> `ssh -i ~/.ssh/deploy_key` and store the private key as the `SSH_KEY`
> secret.

---

## Part 3 — First deploy

You have two ways to trigger the workflow:

```bash
# From your laptop — push anything to main:
git push origin main
```

…or open the repo on GitHub → **Actions** → **Deploy** → **Run workflow** (and
optionally tick `skip_steam_update: true` once you know L4D2 is already
current to skip the 5 GB re-validate).

### What you'll see in the Actions run

Each step is a `::group::` you can expand. In order:

1. **Checkout this repo** — including the vendored `SourceMod/` compiler tree.
2. **Checkout SirPlease/L4D2-Competitive-Rework** at the pinned tag (`v1.0.0`
   by default; bump `ZONEMOD_RELEASE_TAG` in `deploy.yml` to update).
3. **Install build & deploy dependencies** — `wine` (to run `spcomp.exe`),
   `sshpass`, `rsync`.
4. **Compile Bizzymod plugins** — merges this repo's + zonemod's `.sp` into
   the SourceMod scripting dir, then runs `spcomp.exe` for each `.smx` listed
   in `addons/sourcemod/plugins/bizzymod/`. Failures abort the deploy with the
   compiler output.
5. **Download SirPlease zonemod Linux release tarball** — the
   ready-to-overlay binary release.
6. **Token-replace** — substitutes every `#{Token}#` placeholder in `**/*.cfg`
   using your secrets/variables.
7. **Prepare SSH** — adds the server's host key to `known_hosts`.
8. **Stop server, sync logs, refresh L4D2, deploy overlay, restart** — the
   long step:
   - `systemctl stop bizzymod-campaign`
   - copy `left4dead2/logs/` and `addons/sourcemod/logs/` to `/home/campaign/bizzy*logs/`
   - `steamcmd app_update 222860 validate` (skipped if you ticked `skip_steam_update`)
   - rsync zonemod overlay onto `/home/campaign/Steam/steamapps/common/l4d2/left4dead2/`
   - rsync this repo on top (this repo wins on conflict)
   - permissions: `755` on dirs, `644` on files, `+x` on `srcds_run`/`srcds_linux`
   - `systemctl start bizzymod-campaign` + status

### 3.1 Smoke test from your client

Once the workflow goes green:

1. Launch L4D2 on your gaming machine.
2. Open the console (`~`).
3. `connect <server-ip>:27015`

You should join the matchmode the start map selects. From the server side:

```bash
ssh youradmin@<server-ip>
sudo journalctl -u bizzymod-campaign -f
# Watch for client connect lines, no rapid restart loop, no SM plugin load failures.
```

If something fails, see the troubleshooting matrix below.

---

## Operations runbook

### Day-to-day

```bash
# Status / control
sudo systemctl status  bizzymod-campaign
sudo systemctl restart bizzymod-campaign
sudo systemctl stop    bizzymod-campaign

# Live logs
sudo journalctl -u bizzymod-campaign -f

# Tail recent
sudo journalctl -u bizzymod-campaign -n 200 --no-pager
```

### Tuning launch flags

Edit `/home/campaign/.config/bizzymod-campaign.env` then
`sudo systemctl restart bizzymod-campaign`. Knobs available: `PORT`,
`TICKRATE`, `MAXPLAYERS`, `STARTMAP`, `SERVERCFG`, `IP`.

### Firewall

```bash
sudo ufw status verbose         # current rules
sudo ufw allow 27020/udp        # e.g. open SourceTV
sudo ufw delete <num>           # remove by line number from "ufw status numbered"
```

### Bans

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client status recidive

# Manually unban (you, after typing your password wrong too many times)
sudo fail2ban-client set sshd unbanip 1.2.3.4

# Manually ban a known abuser
sudo fail2ban-client set sshd banip 1.2.3.4
```

### GeoIP blocklist

```bash
# Edit which countries are blocked
sudo vim /etc/bizzymod/geoblock.conf
sudo systemctl start bizzymod-geoip-update.service     # apply immediately
sudo systemctl list-timers bizzymod-geoip-update.timer # next scheduled refresh

# Inspect current ipset
sudo ipset list geoblock  | head -30
sudo ipset list geoblock6 | head -30

# Test whether an IP is in the blocklist
sudo ipset test geoblock 1.2.3.4
```

### Updating zonemod or steamcmd

- **Newer zonemod release** — bump `ZONEMOD_RELEASE_TAG` in
  `.github/workflows/deploy.yml`, commit, push.
- **L4D2 game update from Valve** — push any commit to `main` (or just run
  the workflow manually) — the `steamcmd app_update` step re-validates the
  install.

### Disaster recovery — server is borked, start over

```bash
# Snapshot logs
sudo cp -a /home/campaign/Steam/steamapps/common/l4d2/left4dead2/logs ~/saved-logs

# Wipe and re-deploy
sudo systemctl stop bizzymod-campaign
sudo rm -rf /home/campaign/Steam/steamapps/common/l4d2/left4dead2
# Re-run the GH Actions Deploy workflow with skip_steam_update=false to fully
# reinstall L4D2, then redeploy overlays.
```

The bootstrap itself never destroys the L4D2 install or the campaign user's
home directory on re-run.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `sshpass: Permission denied (publickey,password)` | `PasswordAuthentication no` in sshd, or wrong secret | `sudo grep -i password /etc/ssh/sshd_config*` — should show `PasswordAuthentication yes`. Check `SSH_PASSWORD` secret has no trailing whitespace. |
| `sudo: a password is required` mid-workflow | `SUDO_PASSWORD` not set or wrong | Set the `SUDO_PASSWORD` secret. Usually same as `SSH_PASSWORD`. |
| Workflow times out on "Prepare SSH" | UFW dropping your runner's IP, or wrong host | Verify `SSH_HOST`, `SSH_PORT`. Confirm `sudo ufw status` shows your SSH port allowed. Confirm the runner isn't in a geoblocked country (GitHub-hosted runners are in the US — should be fine). |
| Plugin compile fails with `<x>.inc: cannot read from file` | zonemod tag bump removed an include this repo depends on | Pin `ZONEMOD_RELEASE_TAG` back, or add the missing include under `addons/sourcemod/scripting/include/` |
| Service crash-loops after deploy | `.smx` rejected by SourceMod | `sudo journalctl -u bizzymod-campaign -n 300` — look for `[SM] Plugin <x> failed to load`. Disable that plugin's `sm plugins load …` line in the relevant cfg. |
| `bad interpreter: /bin/sh^M` | CRLF on a shell script | `.gitattributes` normalizes to LF; rebooting helps after a re-clone. `dos2unix .deploy/*.sh` as a one-off fix. |
| L4D2 update breaks server | Valve pushed an update mid-week | Re-run workflow (it will `app_update`). If srcds binaries changed, may need to also `apt update` for new lib versions. |

---

## What this replaces vs the old ADO pipeline

The Azure DevOps Release export at `.cicd/AzureDevOpsReleaseExport.json` is the
historical source of truth. Every step in `deploy.yml` has a one-to-one ADO
ancestor, with two intentional improvements:

1. **`chmod -R 777` → `755`/`644`+`+x`.** 777 on a public box is a foothold
   for any local attacker (or rogue plugin); 755/644 is identical for our
   needs.
2. **`/etc/init.d/srcdsCampaign` → systemd unit.** Real logs via
   `journalctl`, auto-restart on crash, clean stop semantics.

Plus everything in `Part 1` — the entire hardening layer — is new. The ADO
pipeline assumed someone had already done that work by hand.
