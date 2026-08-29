#!/usr/bin/env bash
# ============================================================================
# .deploy/srcds-launch.sh — L4D2 launch wrapper for the systemd unit.
#
# Reads knobs from ~/.config/bizzymod-campaign.env (installed by bootstrap.sh)
# and execs srcds_run. Kept deliberately small; all game config lives in the
# deployed cfg/ (server1.cfg -> campaign.cfg).
#
# Why +servercfgfile (not +exec): passing the config via -servercfgfile makes
# srcds re-exec THIS file (server1.cfg) as the authoritative server config on
# every map load, which suppresses the vanilla/zonemod cfg/server.cfg auto-exec
# that would otherwise reset survivor_limit on map transitions.
# ============================================================================
set -euo pipefail

ENV_FILE="${1:-${HOME}/.config/bizzymod-campaign.env}"
if [[ -f "${ENV_FILE}" ]]; then
    set -a; . "${ENV_FILE}"; set +a
fi

INSTALL_DIR="${INSTALL_DIR:-${HOME}/Steam/steamapps/common/l4d2}"
IP="${IP:-0.0.0.0}"
PORT="${PORT:-27015}"
TICKRATE="${TICKRATE:-100}"
MAXPLAYERS="${MAXPLAYERS:-32}"     # engine hard cap; l4dtoolz raises the survivor slots within this
STARTMAP="${STARTMAP:-c1m1_hotel}"
SERVERCFG="${SERVERCFG:-server1.cfg}"

cd "${INSTALL_DIR}" || { echo "FATAL: INSTALL_DIR '${INSTALL_DIR}' not found" >&2; exit 1; }
[[ -x ./srcds_run ]] || { echo "FATAL: ./srcds_run not found/executable in ${INSTALL_DIR}" >&2; exit 1; }

exec ./srcds_run \
    -game left4dead2 \
    -ip "${IP}" \
    -port "${PORT}" \
    -tickrate "${TICKRATE}" \
    -maxplayers "${MAXPLAYERS}" \
    -timeout 10 \
    -norestart \
    +sv_clockcorrection_msecs 25 \
    +servercfgfile "${SERVERCFG}" \
    +map "${STARTMAP}"
