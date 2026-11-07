#!/usr/bin/env bash
# ============================================================================
# bizzymod-campaign / .deploy/bootstrap.sh
#
# One-shot, idempotent prep of a fresh Ubuntu 22.04 / 24.04 LTS server into a
# hardened L4D2 / Source / steamcmd game host. Re-runnable any time to apply
# new defaults or recover from drift.
#
# WHAT IT DOES (in order)
#   0. Preflight: root check, OS check, knob parsing
#   1. System update + base packages
#   2. SSH user (admin) hardening — disable root SSH, restrict AllowUsers
#   3. SSH daemon hardening (sshd_config drop-in, banner, strong crypto)
#   4. UFW firewall (default deny inbound; allow SSH + UDP 27015 game)
#   5. GeoIP blocklist: ipset + UFW splice + weekly refresh timer
#   6. fail2ban (sshd aggressive jail + recidive)
#   7. Unattended security upgrades (no auto-reboot)
#   8. Kernel / sysctl hardening
#   9. i386 multiarch + L4D2 runtime libs
#  10. `srcds` user + home
#  11. steamcmd install (as the srcds user)
#  12. Initial L4D2 dedicated server install (~5 GB; skippable)
#  13. srcds launch wrapper + systemd unit + env file
#  14. Logrotate for L4D2 + SourceMod logs
#  15. Summary + next-step pointer
#
# USAGE
#   git clone https://github.com/<you>/bizzymod.git
#   cd bizzymod
#   sudo SSH_USER=youradmin bash .deploy/bootstrap.sh
#
# KNOBS (env vars, all optional; defaults shown)
#   SRCDS_USER=campaign            # unix user that runs srcds_run
#   SRCDS_PORT=27015               # UDP game port
#   SSH_USER=$(logname)            # user GH Actions / you will SSH in as
#   SSH_PORT=22                    # change for security-by-obscurity if you like
#   SKIP_L4D2_INSTALL=0            # 1 = skip the 5 GB download (just reuse existing)
#   SKIP_GEOIP=0                   # 1 = don't install ipset / blocklist
#   GEOBLOCK_GAME_PORT=0           # 1 = also block game port from geoblocked countries
#
# Re-running is safe; each phase is guarded.
# ============================================================================

set -euo pipefail

# ---- knobs --------------------------------------------------------------
SRCDS_USER="${SRCDS_USER:-campaign}"
SRCDS_PORT="${SRCDS_PORT:-27015}"
SSH_USER="${SSH_USER:-$(logname 2>/dev/null || echo '')}"
SSH_PORT="${SSH_PORT:-22}"
SKIP_L4D2_INSTALL="${SKIP_L4D2_INSTALL:-0}"
SKIP_GEOIP="${SKIP_GEOIP:-0}"
GEOBLOCK_GAME_PORT="${GEOBLOCK_GAME_PORT:-0}"

SRCDS_HOME="/home/${SRCDS_USER}"
INSTALL_DIR="${SRCDS_HOME}/Steam/steamapps/common/l4d2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/server"
# -------------------------------------------------------------------------

log()      { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
substep()  { printf '    \033[0;90m· %s\033[0m\n' "$*"; }
warn()     { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()      { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "bootstrap.sh must run as root (use sudo)."

if [[ -z "${SSH_USER}" ]]; then
    die "Could not determine your SSH_USER. Re-run with: sudo SSH_USER=youradmin bash .deploy/bootstrap.sh"
fi
if [[ "${SSH_USER}" == "root" ]]; then
    die "SSH_USER must be a non-root admin user. Create one first: adduser youradmin && usermod -aG sudo youradmin"
fi
if ! id "${SSH_USER}" >/dev/null 2>&1; then
    die "SSH_USER='${SSH_USER}' does not exist. Create it first: adduser ${SSH_USER} && usermod -aG sudo ${SSH_USER}"
fi
[[ -d "${ASSETS_DIR}" ]] || die "Missing assets directory: ${ASSETS_DIR}. Run from the repo root."

# Detect OS
. /etc/os-release
UBUNTU_VERSION="${VERSION_ID:-unknown}"
[[ "${ID:-}" == "ubuntu" ]] || warn "Detected ${ID:-unknown} — bootstrap is tested on Ubuntu 22.04/24.04 only."
case "${UBUNTU_VERSION}" in
    22.04|24.04) : ;;
    *) warn "Ubuntu ${UBUNTU_VERSION} is not in the tested matrix; proceeding anyway." ;;
esac

# ============================================================================
log "[0/14] Preflight"
substep "Ubuntu ${UBUNTU_VERSION}"
substep "Admin SSH user:    ${SSH_USER}"
substep "Game srcds user:   ${SRCDS_USER}"
substep "SSH port:          ${SSH_PORT}"
substep "Game port (UDP):   ${SRCDS_PORT}"
substep "Install dir:       ${INSTALL_DIR}"
substep "Skip L4D2 install: ${SKIP_L4D2_INSTALL}"
substep "Skip GeoIP setup:  ${SKIP_GEOIP}"
substep "Block geo on game: ${GEOBLOCK_GAME_PORT}"

# Snapshot critical files we're about to modify (timestamped backups under /root).
BACKUP_DIR="/root/bizzymod-bootstrap-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"
substep "Backups will go to ${BACKUP_DIR}"

# ============================================================================
log "[1/14] System update + base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get install -y --no-install-recommends \
    ca-certificates curl wget tar gzip xz-utils gnupg \
    sudo rsync screen tmux htop iotop net-tools dnsutils \
    ufw fail2ban ipset unattended-upgrades apt-listchanges \
    chrony logrotate file lsof psmisc procps less vim

# Make sure time sync is on; an out-of-sync clock breaks SteamCMD signatures.
systemctl enable --now chrony.service >/dev/null 2>&1 || \
    systemctl enable --now chronyd.service >/dev/null 2>&1 || \
    systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true

# ============================================================================
log "[2/14] SSH admin user prep"
# Make sure SSH_USER is in sudo
if ! id -nG "${SSH_USER}" | tr ' ' '\n' | grep -qx sudo; then
    usermod -aG sudo "${SSH_USER}"
    substep "Added ${SSH_USER} to 'sudo' group"
fi

# Make sure their home / .ssh perms are sane (only block-deny, never auto-grant keys).
install -d -o "${SSH_USER}" -g "${SSH_USER}" -m 0700 "/home/${SSH_USER}/.ssh"

# ============================================================================
log "[3/14] SSH daemon hardening"
cp -a /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config"
install -m 0644 "${ASSETS_DIR}/sshd-hardening.conf" /etc/ssh/sshd_config.d/99-bizzymod-hardening.conf

# Append AllowUsers (idempotent; replace existing line)
sed -i '/^AllowUsers /d' /etc/ssh/sshd_config.d/99-bizzymod-hardening.conf
echo "AllowUsers ${SSH_USER}" >> /etc/ssh/sshd_config.d/99-bizzymod-hardening.conf

# Custom SSH port
if [[ "${SSH_PORT}" != "22" ]]; then
    sed -i '/^Port /d' /etc/ssh/sshd_config.d/99-bizzymod-hardening.conf
    echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config.d/99-bizzymod-hardening.conf
fi

# Banner
install -m 0644 "${ASSETS_DIR}/issue.net" /etc/issue.net

# Validate before reloading, to avoid locking ourselves out.
if ! sshd -t 2>/dev/null; then
    warn "sshd config test FAILED — rolling back hardening drop-in"
    rm -f /etc/ssh/sshd_config.d/99-bizzymod-hardening.conf
    sshd -t
    die "Fix the upstream /etc/ssh/sshd_config and re-run bootstrap."
fi
systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service

substep "sshd: PermitRootLogin=no, MaxAuthTries=3, AllowUsers=${SSH_USER}, Port=${SSH_PORT}"

# ============================================================================
log "[4/14] UFW firewall"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

# SSH (rate-limited at UFW layer too)
ufw limit "${SSH_PORT}/tcp" comment "ssh (rate-limited)"

# Game port — UDP only. RCON over TCP intentionally not opened (use sm_rcon
# instead, or restrict to specific IPs if you really need raw RCON).
ufw allow "${SRCDS_PORT}/udp" comment "L4D2 srcds (game)"
# SourceTV (if you enable it) — uncomment:
# ufw allow 27020/udp comment "L4D2 SourceTV"

# ============================================================================
if [[ "${SKIP_GEOIP}" == "1" ]]; then
    log "[5/14] GeoIP blocklist (SKIPPED via SKIP_GEOIP=1)"
else
    log "[5/14] GeoIP blocklist (ipset + UFW splice + weekly refresh)"

    install -d -m 0755 /etc/bizzymod
    if [[ ! -f /etc/bizzymod/geoblock.conf ]]; then
        install -m 0644 "${ASSETS_DIR}/geoblock.conf" /etc/bizzymod/geoblock.conf
    else
        substep "/etc/bizzymod/geoblock.conf already exists — keeping your edits"
    fi

    install -m 0755 "${ASSETS_DIR}/bizzymod-geoip-update" /usr/local/sbin/bizzymod-geoip-update
    install -m 0644 "${ASSETS_DIR}/bizzymod-geoip-restore.service" /etc/systemd/system/bizzymod-geoip-restore.service
    install -m 0644 "${ASSETS_DIR}/bizzymod-geoip-update.service"  /etc/systemd/system/bizzymod-geoip-update.service
    install -m 0644 "${ASSETS_DIR}/bizzymod-geoip-update.timer"    /etc/systemd/system/bizzymod-geoip-update.timer

    # Create the live sets immediately so the UFW rules below have something to match.
    ipset create -exist geoblock  hash:net family inet  hashsize 65536 maxelem 524288
    ipset create -exist geoblock6 hash:net family inet6 hashsize 16384 maxelem 131072

    # Splice the blocklist drop into ufw's before.rules (idempotent).
    splice_into_ufw() {
        local rules_file="$1" snippet="$2" marker="$3"
        cp -a "${rules_file}" "${BACKUP_DIR}/$(basename "${rules_file}")"
        if grep -q "${marker}" "${rules_file}"; then
            # Already spliced; replace the existing block atomically.
            python3 - "${rules_file}" "${snippet}" "${marker}" <<'PY'
import sys, pathlib, re
path, snippet, marker = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
new = pathlib.Path(snippet).read_text()
pattern = re.compile(rf"# -+\s*\n# {re.escape(marker)}.*?(?=\n\*|\n# END BIZZYMOD|\Z)", re.S)
# Simple approach: between markers we manage. Use BEGIN/END markers we own.
begin = "# >>> BIZZYMOD-GEOIP-BEGIN >>>"
end   = "# <<< BIZZYMOD-GEOIP-END <<<"
if begin in text and end in text:
    text = re.sub(re.escape(begin)+r".*?"+re.escape(end), begin+"\n"+new.strip()+"\n"+end, text, flags=re.S)
else:
    text = text.replace("*filter", "*filter\n"+begin+"\n"+new.strip()+"\n"+end+"\n", 1)
pathlib.Path(path).write_text(text)
PY
        else
            # First-time splice. Insert right after "*filter".
            python3 - "${rules_file}" "${snippet}" <<'PY'
import sys, pathlib
path, snippet = sys.argv[1], sys.argv[2]
text = pathlib.Path(path).read_text()
new = pathlib.Path(snippet).read_text()
begin = "# >>> BIZZYMOD-GEOIP-BEGIN >>>"
end   = "# <<< BIZZYMOD-GEOIP-END <<<"
block = begin + "\n" + new.strip() + "\n" + end + "\n"
if "*filter" in text:
    text = text.replace("*filter\n", "*filter\n"+block, 1)
else:
    text += "\n" + block
pathlib.Path(path).write_text(text)
PY
        fi
    }

    splice_into_ufw /etc/ufw/before.rules  "${ASSETS_DIR}/ufw-before-rules-snippet.txt"  "BIZZYMOD-GEOIP"
    splice_into_ufw /etc/ufw/before6.rules "${ASSETS_DIR}/ufw-before6-rules-snippet.txt" "BIZZYMOD-GEOIP"

    if [[ "${GEOBLOCK_GAME_PORT}" == "1" ]]; then
        substep "Extending geoblock to UDP ${SRCDS_PORT} (GEOBLOCK_GAME_PORT=1)"
        cat >> /etc/ufw/before.rules <<EOF

# Block UDP ${SRCDS_PORT} from geo-blocked sources
-A ufw-before-input -m set --match-set geoblock src -p udp --dport ${SRCDS_PORT} -j DROP
EOF
        cat >> /etc/ufw/before6.rules <<EOF

# Block UDP ${SRCDS_PORT} from geo-blocked sources (v6)
-A ufw6-before-input -m set --match-set geoblock6 src -p udp --dport ${SRCDS_PORT} -j DROP
EOF
    fi

    systemctl daemon-reload
    systemctl enable bizzymod-geoip-restore.service >/dev/null
    systemctl enable --now bizzymod-geoip-update.timer >/dev/null

    # Pull blocklist down immediately so the first reload of UFW has data.
    substep "Downloading initial GeoIP blocklist (this can take a minute)…"
    /usr/local/sbin/bizzymod-geoip-update || warn "Initial GeoIP download failed; timer will retry."
fi

# Enable UFW (sources are now in place).
ufw --force enable
substep "ufw: $(ufw status | head -1)"

# ============================================================================
log "[6/14] fail2ban (sshd aggressive + recidive)"
cp -a /etc/fail2ban/jail.conf "${BACKUP_DIR}/jail.conf" 2>/dev/null || true
install -m 0644 "${ASSETS_DIR}/fail2ban-jail.local" /etc/fail2ban/jail.local
# Patch SSH port if customized
sed -i "s/^port\s*=\s*ssh\s*$/port    = ${SSH_PORT}/" /etc/fail2ban/jail.local
systemctl enable --now fail2ban.service
systemctl reload fail2ban.service || systemctl restart fail2ban.service
substep "fail2ban: $(fail2ban-client status | tr -d '\n' | sed 's/.*Jail list://')"

# ============================================================================
log "[7/14] Unattended security upgrades"
install -m 0644 "${ASSETS_DIR}/20auto-upgrades-bizzymod"     /etc/apt/apt.conf.d/20auto-upgrades
install -m 0644 "${ASSETS_DIR}/50unattended-upgrades-bizzymod" /etc/apt/apt.conf.d/52bizzymod-unattended-upgrades
systemctl enable --now unattended-upgrades.service
substep "Security updates apply automatically; reboots are manual."

# ============================================================================
log "[8/14] Kernel / sysctl hardening"
install -m 0644 "${ASSETS_DIR}/sysctl-hardening.conf" /etc/sysctl.d/99-bizzymod-hardening.conf
sysctl --system >/dev/null
substep "sysctl: applied /etc/sysctl.d/99-bizzymod-hardening.conf"

# ============================================================================
log "[9/14] i386 multiarch + L4D2 runtime libs"
dpkg --add-architecture i386
apt-get update -y
apt-get install -y --no-install-recommends \
    lib32gcc-s1 lib32stdc++6 libc6:i386 libstdc++6:i386 \
    libcurl4-gnutls-dev:i386 lib32z1 libtinfo6:i386 libncurses6:i386
substep "32-bit libs installed"

# ============================================================================
log "[10/14] srcds user '${SRCDS_USER}'"
if ! id "${SRCDS_USER}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --comment "L4D2 dedicated server" "${SRCDS_USER}"
    substep "Created system user ${SRCDS_USER}"
fi
install -d -o "${SRCDS_USER}" -g "${SRCDS_USER}" -m 0755 \
    "${SRCDS_HOME}/.config" \
    "${SRCDS_HOME}/bizzylogs" \
    "${SRCDS_HOME}/bizzysourcemodlogs"

# ============================================================================
log "[11/14] steamcmd"
if [[ ! -x "${SRCDS_HOME}/steamcmd/steamcmd.sh" ]]; then
    sudo -u "${SRCDS_USER}" -H bash -lc "
        set -euo pipefail
        mkdir -p ~/steamcmd
        cd ~/steamcmd
        curl -fsSL https://media.steampowered.com/installer/steamcmd_linux.tar.gz | tar xz
    "
    substep "steamcmd installed at ${SRCDS_HOME}/steamcmd/"
else
    substep "steamcmd already present"
fi

# ============================================================================
log "[12/14] L4D2 dedicated server (app 222860)"
if [[ "${SKIP_L4D2_INSTALL}" == "1" ]]; then
    substep "SKIPPED via SKIP_L4D2_INSTALL=1"
else
    sudo -u "${SRCDS_USER}" -H bash -lc "
        set -euo pipefail
        cd ~/steamcmd
        ./steamcmd.sh +force_install_dir '${INSTALL_DIR}' +login anonymous +app_update 222860 validate +quit
    "
    substep "L4D2 installed/validated at ${INSTALL_DIR}"
fi

# ============================================================================
log "[13/14] srcds launch wrapper + systemd unit"
install -m 0755 -o "${SRCDS_USER}" -g "${SRCDS_USER}" \
    "${SCRIPT_DIR}/srcds-launch.sh" "${SRCDS_HOME}/srcds-launch.sh"

# Render service file (substitute user/home/group)
sed \
    -e "s|User=campaign|User=${SRCDS_USER}|g" \
    -e "s|Group=campaign|Group=${SRCDS_USER}|g" \
    -e "s|/home/campaign|${SRCDS_HOME}|g" \
    "${SCRIPT_DIR}/bizzymod-campaign.service" > /etc/systemd/system/bizzymod-campaign.service

# Default env file (preserve existing edits)
if [[ ! -f "${SRCDS_HOME}/.config/bizzymod-campaign.env" ]]; then
    cat > "${SRCDS_HOME}/.config/bizzymod-campaign.env" <<EOF
# Bizzymod Campaign launch env. After editing: sudo systemctl restart bizzymod-campaign
INSTALL_DIR=${INSTALL_DIR}
PORT=${SRCDS_PORT}
TICKRATE=100
MAXPLAYERS=16
STARTMAP=c5m1_waterfront
SERVERCFG=server1.cfg
IP=0.0.0.0
EOF
    chown "${SRCDS_USER}:${SRCDS_USER}" "${SRCDS_HOME}/.config/bizzymod-campaign.env"
    chmod 0640 "${SRCDS_HOME}/.config/bizzymod-campaign.env"
fi

systemctl daemon-reload
systemctl enable bizzymod-campaign.service >/dev/null
substep "Service installed (NOT started yet — first deploy will lay content & start it)"

# ============================================================================
log "[14/14] Logrotate"
sed \
    -e "s|#INSTALL_DIR#|${INSTALL_DIR}|g" \
    -e "s|#SRCDS_USER#|${SRCDS_USER}|g" \
    "${ASSETS_DIR}/logrotate-l4d2" > /etc/logrotate.d/bizzymod-l4d2
chmod 0644 /etc/logrotate.d/bizzymod-l4d2
# Validate logrotate config without acting.
logrotate -d /etc/logrotate.d/bizzymod-l4d2 >/dev/null 2>&1 || warn "logrotate config dry-run reported issues; check /etc/logrotate.d/bizzymod-l4d2"

# ============================================================================
echo
printf '\033[1;32m================================================================\033[0m\n'
printf '\033[1;32m  Bizzymod server bootstrap complete on Ubuntu %s\033[0m\n' "${UBUNTU_VERSION}"
printf '\033[1;32m================================================================\033[0m\n'
cat <<EOF

  Admin SSH:      ssh -p ${SSH_PORT} ${SSH_USER}@$(hostname -I | awk '{print $1}')
  Game endpoint:  $(hostname -I | awk '{print $1}'):${SRCDS_PORT}/udp
  Install dir:    ${INSTALL_DIR}
  Service:        sudo systemctl status bizzymod-campaign
  Live logs:      sudo journalctl -u bizzymod-campaign -f
  Firewall:       sudo ufw status verbose
  Bans:           sudo fail2ban-client status sshd
  GeoIP:          sudo systemctl status bizzymod-geoip-update.timer
                  edit:  /etc/bizzymod/geoblock.conf
                  apply: sudo systemctl start bizzymod-geoip-update.service

  Backups of overwritten files: ${BACKUP_DIR}

  NEXT STEPS — see DEPLOY.md in the repo:
    1. On GitHub, set Actions secrets/variables (SSH_HOST, SSH_USER,
       SSH_PASSWORD, SUDO_PASSWORD, plus the variables listed in DEPLOY.md).
    2. Push to main, or run the "Deploy" workflow manually.
    3. The deploy will lay zonemod + this repo onto ${INSTALL_DIR}/left4dead2
       and start the service.

EOF
