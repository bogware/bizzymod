#!/usr/bin/env bash
# .deploy/moonland/build.sh — build or rebuild Bizzy's Moonland on a game host.
#
# Layers, bottom to top:
#   1. current L4D2 game files, copied from an existing up-to-date install
#      (addons/, cfg/, scripts/, logs/ excluded) + Valve's stock cfg files
#   2. SirPlease zonemod release (Metamod, SourceMod, l4dtoolz, tickrate_enabler,
#      stripper, fixes)                              — ZONEMOD_RELEASE_TAG
#   3. Moon's BizzyMoon repo at a pinned commit      — UPSTREAM_REPO/UPSTREAM_REF
#   4. servers/moonland/ overlay, token-replaced     — this repo wins
#   5. settings from servers/moonland/deploy.env (hostname, restart grace,
#      disabled plugins, guaranteed admins)
#
# Runtime state survives rebuilds: the bizzymod_stats server key (the server's
# stats identity), SourceMod sqlite data, and logs.
#
# Usage — on the game host, as root, from a checkout of this repo:
#   export SERVER_IP=<host ip>  SERVER_NAME="Bizzy's Moonland"   # optional; defaults from deploy.env
#   export SOURCEBANS_DB=... SOURCEBANS_DB_IP=... SOURCEBANS_PORT=... SOURCEBANS_USER=... SOURCEBANS_PASS=...
#   export L4DSTATS_DB_IP=... L4DSTATS_PORT=... L4DSTATS_USER=... L4DSTATS_PASS=...
#   .deploy/moonland/build.sh --base-game /home/<user>/Steam/steamapps/common/l4d2
#
#   --stage-only DIR   assemble the full tree into DIR and stop (no user, service,
#                      cron, firewall or restart). Use it to review a build first.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=/dev/null
source "$REPO/servers/moonland/deploy.env"

BASE_GAME=""; STAGE_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-game)  BASE_GAME=$2; shift 2 ;;
    --stage-only) STAGE_ONLY=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE_GAME" ] && [ -x "$BASE_GAME/srcds_run" ] \
  || { echo "--base-game must point at a current l4d2 install (contains srcds_run)" >&2; exit 2; }

: "${SERVER_NAME:=$SERVER_NAME_DEFAULT}"; export SERVER_NAME
if [ -n "$STAGE_ONLY" ]; then GAME=$STAGE_ONLY; else GAME=/home/$SRCDS_USER/Steam/steamapps/common/l4d2; fi
LD=$GAME/left4dead2
CACHE=/root/.cache/moonland; mkdir -p "$CACHE"
INIT=/etc/init.d/srcdsMoonland
say(){ echo "== $*"; }

if [ -z "$STAGE_ONLY" ]; then
  [ -x "$INIT" ] && { say "stopping server"; "$INIT" stop >/dev/null 2>&1 || true; }
  id "$SRCDS_USER" >/dev/null 2>&1 || { say "creating user $SRCDS_USER"; useradd -m -s /bin/bash "$SRCDS_USER"; }
fi

say "preserving runtime state"
KEEP=$(mktemp -d)
for p in addons/sourcemod/data/bizzymod_stats.server_key addons/sourcemod/data/sqlite addons/sourcemod/logs logs; do
  if [ -e "$LD/$p" ]; then mkdir -p "$KEEP/$(dirname "$p")"; cp -a "$LD/$p" "$KEEP/$p"; fi
done

say "1. game files from $BASE_GAME"
mkdir -p "$GAME"
rsync -a --delete \
  --exclude 'left4dead2/addons/' --exclude 'left4dead2/cfg/' --exclude 'left4dead2/scripts/' \
  --exclude 'left4dead2/logs/' --exclude 'left4dead2/downloads/' --exclude 'left4dead2/console.log' \
  "$BASE_GAME/" "$GAME/"
rm -rf "$LD/addons" "$LD/cfg" "$LD/scripts"; mkdir -p "$LD/cfg"
# Valve's stock cfg files must exist as loose files: valve.rc ends with `stuffcmds`,
# which is what runs the +map/+servercfgfile launch args. Without it srcds idles.
while read -r f; do
  [ -n "$f" ] && cp -p "$BASE_GAME/left4dead2/cfg/$f" "$LD/cfg/$f"
done < "$REPO/.deploy/moonland/stock-cfg.txt"
[ -f "$LD/cfg/valve.rc" ] || { echo "valve.rc missing after stock copy" >&2; exit 1; }

say "2. zonemod $ZONEMOD_RELEASE_TAG"
ZM=$CACHE/zonemod-$ZONEMOD_RELEASE_TAG-linux.tar.gz
[ -s "$ZM" ] || curl -fsSL -o "$ZM" \
  "https://github.com/SirPlease/L4D2-Competitive-Rework/releases/download/$ZONEMOD_RELEASE_TAG/L4D2-Competitive-Rework-$ZONEMOD_RELEASE_TAG-linux.tar.gz"
tar -xzf "$ZM" -C "$LD"

say "3. upstream $UPSTREAM_REPO @ ${UPSTREAM_REF:0:7}"
UP=$CACHE/upstream
[ -d "$UP/.git" ] || git clone -q "$UPSTREAM_REPO" "$UP"
git -C "$UP" fetch -q origin
git -C "$UP" checkout -q --detach "$UPSTREAM_REF"
rsync -a --exclude '.git' --exclude '.gitattributes' --exclude '.gitignore' \
  --exclude 'README.md' --exclude 'LICENSE' --exclude 'guide/' "$UP/" "$LD/"
# Never ship literal RCON passwords from upstream cfgs; RCON stays off unless the
# overlay sets it through a token.
grep -rlE '^[[:space:]]*(sm_cvar[[:space:]]+)?rcon_password[[:space:]]+"[^"#]' "$LD/cfg" 2>/dev/null \
  | while read -r c; do
      sed -i -E 's/^([[:space:]]*(sm_cvar[[:space:]]+)?rcon_password[[:space:]]+)"[^"#][^"]*"/\1""/' "$c"
    done || true
# Upstream hardcodes its own hostname; rewrite it (literal match, no regex).
grep -rlF "$HOSTNAME_FROM" "$LD/cfg" 2>/dev/null \
  | FROM="$HOSTNAME_FROM" TO="$SERVER_NAME" xargs -r perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' || true
# Any leftover upstream token for the server name.
grep -rlF '#{Server_Name}#' "$LD/cfg" 2>/dev/null \
  | TO="$SERVER_NAME" xargs -r perl -pi -e 's/#\{Server_Name\}#/$ENV{TO}/g' || true

say "4. servers/moonland overlay (token-replaced)"
ST=$(mktemp -d)
rsync -a --exclude 'deploy.env' --exclude 'README.md' "$REPO/servers/moonland/" "$ST/"
"$REPO/.deploy/replace-tokens.sh" "$ST"
rsync -a "$ST/" "$LD/"
rm -rf "$ST"

say "5. deploy.env settings"
RE="$LD/cfg/sourcemod/sm_restart_empty.cfg"
[ -f "$RE" ] && V="$RESTART_EMPTY_DELAY" perl -pi -e 's/^(sm_restart_empty_delay\s+)"[^"]*"/$1"$ENV{V}"/' "$RE"
for p in $DISABLE_PLUGINS; do
  if [ -f "$LD/addons/sourcemod/plugins/$p" ]; then
    mkdir -p "$LD/addons/sourcemod/plugins/disabled"
    mv "$LD/addons/sourcemod/plugins/$p" "$LD/addons/sourcemod/plugins/disabled/"
  fi
done
ADM="$LD/addons/sourcemod/configs/admins_simple.ini"
for e in $ENSURE_ADMINS; do
  IFS='|' read -r sid imm flg lbl <<< "$e"
  acct=${sid#STEAM_?:}                       # "Y:Z" — same account under STEAM_0/STEAM_1
  grep -qE "STEAM_[01]:${acct}\"" "$ADM" 2>/dev/null \
    || printf '   "%s"\t"%s:%s"\t\t\t\t// %s (guaranteed by servers/moonland/deploy.env)\n' "$sid" "$imm" "$flg" "$lbl" >> "$ADM"
done

say "restoring runtime state"
cp -a "$KEEP/." "$LD/"; rm -rf "$KEEP"

if [ -n "$STAGE_ONLY" ]; then say "stage-only build complete: $GAME"; exit 0; fi

say "6. service"
: "${SERVER_IP:?set SERVER_IP to the host address srcds should bind}"
chown -R "$SRCDS_USER:$SRCDS_USER" "/home/$SRCDS_USER"
sed -e "s/__SERVER_IP__/$SERVER_IP/" -e "s/__GAME_PORT__/$GAME_PORT/" -e "s/__TICKRATE__/$TICKRATE/" \
    -e "s/__START_MAP__/$START_MAP/" -e "s/__SERVERCFGFILE__/$SERVERCFGFILE/" -e "s/__SRCDS_USER__/$SRCDS_USER/" \
    "$REPO/.deploy/moonland/srcdsMoonland.template" > "$INIT"
chmod 755 "$INIT"
crontab -l 2>/dev/null | grep -q "$INIT start" || { crontab -l 2>/dev/null; echo "$CRON_START $INIT start"; } | crontab -
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  ufw status | grep -qE "^$GAME_PORT/udp" || ufw allow "$GAME_PORT/udp" comment "L4D2 srcds (Moonland)"
fi
"$INIT" start
say "done — $SERVER_NAME on :$GAME_PORT"
