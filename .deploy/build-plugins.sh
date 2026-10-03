#!/usr/bin/env bash
# build-plugins.sh — compile all Bizzymod SourcePawn plugins.
#
# Assumes the workflow has run `rumblefrog/setup-sp` first, which:
#   - puts `spcomp` on PATH (a proxy that auto-injects -i<cached SM include>)
#   - exports `$scriptingPath` (cached SM scripting dir)
#   - exports `$includePath`  (cached SM include dir)
#
# Inputs:
#   ./addons/sourcemod/plugins/bizzymod/*.smx   build manifest (basename → .sp)
#   ./addons/sourcemod/scripting/               bizzymod .sp + bizzymod-local includes
#   ./zonemod/addons/sourcemod/scripting/       zonemod source repo (current left4dhooks.inc etc.)
#
# We build in a private mktemp working dir so we don't pollute the cached
# SM scripting tree, and so spcomp can resolve `#include <foo>` against:
#   1. bizzymod's own include/ (highest priority — overlaid first)
#   2. zonemod's include/ (filled in for names bizzymod doesn't have)
#   3. SM stock include/ (via -i injected by the spcomp proxy)
#
# Outputs:
#   compiled .smx written back over ./addons/sourcemod/plugins/bizzymod/*.smx

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Which server (game mode) to build for. Pass the server dir as $1 (or via the
# SERVER_DIR env), relative to repo root or absolute. Each server is
# self-contained under servers/<name>/, so its plugins + scripting live there.
SERVER_DIR_IN="${1:-${SERVER_DIR:-servers/campaign}}"
case "${SERVER_DIR_IN}" in
    /*) SERVER_DIR="${SERVER_DIR_IN}" ;;
    *)  SERVER_DIR="${ROOT}/${SERVER_DIR_IN}" ;;
esac
[ -d "${SERVER_DIR}/addons/sourcemod/scripting" ] || {
    echo "build-plugins: no scripting tree under ${SERVER_DIR}/addons/sourcemod/scripting" >&2
    exit 1
}

BIZZY_PLUGINS="${SERVER_DIR}/addons/sourcemod/plugins/optional/bizzymod"
BIZZY_SCRIPTING="${SERVER_DIR}/addons/sourcemod/scripting"
# zonemod source (for shared includes) is checked out at repo root by the workflow.
ZONE_SCRIPTING="${ROOT}/zonemod/addons/sourcemod/scripting"

# Committed binaries we intentionally ship WITHOUT source (cannot be rebuilt on
# the pinned SM 1.12). Any OTHER manifest .smx lacking a .sp is a FATAL error so
# a placeholder/stale binary can never ship silently.
#   l4d_superversus  - "Super Versus Reloaded 1.8.15.5", SM 1.7 build, no public
#                      source; it is the exact legacy binary and works (sigs
#                      resolve). Kept deliberately (operator decision).
#   Survivor_Legs    - SM 1.9 build, cosmetic first-person legs, no source.
NOSRC_ALLOW="l4d_superversus Survivor_Legs"

if ! command -v spcomp >/dev/null 2>&1; then
    echo "build-plugins: spcomp not on PATH." >&2
    echo "build-plugins: did the workflow's setup-sp step run?" >&2
    exit 1
fi

echo "build-plugins: spcomp at $(command -v spcomp)"
echo "build-plugins: scriptingPath=${scriptingPath:-<unset>}"
echo "build-plugins: includePath=${includePath:-<unset>}"

WORK="$(mktemp -d -t bizzybuild.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

echo "build-plugins: staging bizzymod scripting in ${WORK}"
rsync -a "${BIZZY_SCRIPTING}/" "${WORK}/"

if [[ -d "${ZONE_SCRIPTING}" ]]; then
    echo "build-plugins: overlaying zonemod scripting (--ignore-existing — bizzymod wins)"
    rsync -a --ignore-existing "${ZONE_SCRIPTING}/" "${WORK}/"
else
    echo "build-plugins: WARNING — ${ZONE_SCRIPTING} missing, includes may not resolve" >&2
fi

# Sanity-check: confirm key third-party includes resolved.
for inc in left4dhooks.inc l4d2lib.inc colors.inc multicolors.inc; do
    if [[ -f "${WORK}/include/${inc}" ]]; then
        echo "build-plugins:   include OK: ${inc}"
    else
        echo "build-plugins:   include MISSING: ${inc}" >&2
    fi
done

cd "${WORK}"

failed=0
built=0
fail_list=()

# compile_one <base> <dest_smx>
#   Compile ${base}.sp (staged in WORK) and write the .smx over <dest_smx>.
#   A missing .sp is FATAL unless the base is NOSRC_ALLOW-listed, so a
#   placeholder/stale binary can never ship for a plugin we mean to build.
compile_one() {
    local base="$1" dest="$2"
    local sp="${WORK}/${base}.sp"

    if [[ ! -f "${sp}" ]]; then
        if [[ " ${NOSRC_ALLOW} " == *" ${base} "* ]]; then
            echo "  keep (no .sp, allowlisted committed binary): ${base}.smx"
            return 0
        fi
        echo "  FATAL: ${base}.smx has no matching ${base}.sp and is not in NOSRC_ALLOW" >&2
        failed=$((failed + 1)); fail_list+=("${base}"); return 1
    fi

    echo "  build: ${base}.sp -> ${dest#${SERVER_DIR}/}"
    # spcomp does NOT implicitly search ./include/ — only the dirs from -i flags.
    # The proxy from setup-sp already injects -i<cached SM include>; we add our
    # merged include/ (bizzymod + zonemod overlay) explicitly.
    if ! spcomp "${base}.sp" -i"${WORK}/include" >/tmp/spcomp.${base}.log 2>&1; then
        echo "    FAILED (last 30 lines):"
        tail -n 30 "/tmp/spcomp.${base}.log" | sed 's/^/      /'
        failed=$((failed + 1)); fail_list+=("${base}"); return 1
    fi
    if [[ ! -f "${WORK}/${base}.smx" ]]; then
        echo "    FAILED: spcomp returned 0 but ${base}.smx not produced"
        failed=$((failed + 1)); fail_list+=("${base}"); return 1
    fi
    cp -f "${WORK}/${base}.smx" "${dest}"
    built=$((built + 1))
}

# 1) Strict manifest: every .smx under plugins/optional/bizzymod/ is built from source.
for smx in "${BIZZY_PLUGINS}"/*.smx; do
    [[ -e "${smx}" ]] || { echo "build-plugins: no .smx in ${BIZZY_PLUGINS}; nothing to do."; break; }
    compile_one "$(basename "${smx}" .smx)" "${smx}" || true
done

# 2) Auto-load tray rebuilds: plugins that must live in the AUTO-LOAD plugins/bizzymod/
#    tray (so they are up for idle play, and are reloaded by bizzyload.cfg during
#    confoglcompmod matches after its unload_all) but are still ours to rebuild every
#    deploy. The REST of plugins/bizzymod/ ships as tested pre-built binaries and is
#    intentionally NOT rebuilt here, so only this allowlist is compiled from that tray.
AUTOLOAD_TRAY="${SERVER_DIR}/addons/sourcemod/plugins/bizzymod"
AUTOLOAD_REBUILD=(bizzymod_stats l4d2_force_precache l4d2_mix)
for base in "${AUTOLOAD_REBUILD[@]}"; do
    compile_one "${base}" "${AUTOLOAD_TRAY}/${base}.smx" || true
done

echo ""
echo "build-plugins: ${built} built, ${failed} failed."
if [[ "${failed}" -gt 0 ]]; then
    echo "build-plugins: failed plugin(s): ${fail_list[*]}"
    echo "build-plugins: failed plugin(s) keep their existing .smx in the repo as fallback."
    echo "build-plugins: set BUILD_STRICT=1 to make any compile failure fatal."
    if [[ "${BUILD_STRICT:-0}" == "1" ]]; then
        exit 1
    fi
fi
if [[ "${built}" -eq 0 && "${failed}" -gt 0 ]]; then
    echo "build-plugins: 0 successful builds — toolchain is broken; aborting."
    exit 1
fi
