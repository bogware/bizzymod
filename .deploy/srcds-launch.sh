#!/usr/bin/env bash
# srcds-launch.sh — wrapped invocation of srcds_run for the Bizzymod Campaign server.
# Installed at /home/${SRCDS_USER}/srcds-launch.sh by .deploy/bootstrap.sh.
# Invoked by the systemd unit bizzymod-campaign.service.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/home/campaign/Steam/steamapps/common/l4d2}"
PORT="${PORT:-27015}"
TICKRATE="${TICKRATE:-100}"
MAXPLAYERS="${MAXPLAYERS:-16}"
STARTMAP="${STARTMAP:-c5m1_waterfront}"
SERVERCFG="${SERVERCFG:-server1.cfg}"
IP="${IP:-0.0.0.0}"

cd "${INSTALL_DIR}"

exec ./srcds_run \
    -game left4dead2 \
    -strictportbind \
    -console \
    -nobreakpad \
    -ip "${IP}" \
    -port "${PORT}" \
    +map "${STARTMAP}" \
    +servercfgfile "${SERVERCFG}" \
    -tickrate "${TICKRATE}" \
    -maxplayers "${MAXPLAYERS}"
