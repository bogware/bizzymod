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
BIZZY_PLUGINS="${ROOT}/addons/sourcemod/plugins/bizzymod"
BIZZY_SCRIPTING="${ROOT}/addons/sourcemod/scripting"
ZONE_SCRIPTING="${ROOT}/zonemod/addons/sourcemod/scripting"

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
cp -a "${BIZZY_SCRIPTING}/." "${WORK}/"

if [[ -d "${ZONE_SCRIPTING}" ]]; then
    echo "build-plugins: overlaying zonemod scripting (skip-existing — bizzymod wins)"
    cp -an "${ZONE_SCRIPTING}/." "${WORK}/" || true
else
    echo "build-plugins: WARNING — ${ZONE_SCRIPTING} missing, includes may not resolve" >&2
fi

cd "${WORK}"

failed=0
built=0
fail_list=()

for smx in "${BIZZY_PLUGINS}"/*.smx; do
    [[ -e "${smx}" ]] || { echo "build-plugins: no .smx in ${BIZZY_PLUGINS}; nothing to do."; break; }
    base="$(basename "${smx}" .smx)"
    sp="${WORK}/${base}.sp"

    if [[ ! -f "${sp}" ]]; then
        echo "  skip: ${base}.smx has no matching ${base}.sp in merged tree"
        continue
    fi

    echo "  build: ${base}.sp"
    if ! spcomp "${base}.sp" >/tmp/spcomp.${base}.log 2>&1; then
        echo "    FAILED (last 30 lines):"
        tail -n 30 "/tmp/spcomp.${base}.log" | sed 's/^/      /'
        failed=$((failed + 1))
        fail_list+=("${base}")
        continue
    fi

    out="${WORK}/${base}.smx"
    if [[ ! -f "${out}" ]]; then
        echo "    FAILED: spcomp returned 0 but ${out} not produced"
        failed=$((failed + 1))
        fail_list+=("${base}")
        continue
    fi

    cp -f "${out}" "${smx}"
    built=$((built + 1))
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
