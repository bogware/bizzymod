#!/usr/bin/env bash
# build-plugins.sh — compile all Bizzymod SourcePawn plugins.
#
# Direct translation of the "Build bizzyplugins" PowerShell task in
# .cicd/AzureDevOpsReleaseExport.json.
#
# Inputs (all under repo root):
#   ./addons/sourcemod/plugins/bizzymod/*.smx   the build manifest (basename -> .sp to compile)
#   ./addons/sourcemod/scripting/               this repo's .sp + custom includes
#   ./zonemod/addons/sourcemod/scripting/       zonemod (cloned externally)
#   ./SourceMod/sourcemod/addons/sourcemod/scripting/  compile root with spcomp.exe and base SM include/
#
# Outputs:
#   compiled .smx written back over ./addons/sourcemod/plugins/bizzymod/*.smx
#
# Requires: wine (to run spcomp.exe on a Linux runner).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIZZY_PLUGINS="${ROOT}/addons/sourcemod/plugins/bizzymod"
BIZZY_SCRIPTING="${ROOT}/addons/sourcemod/scripting"
ZONE_SCRIPTING="${ROOT}/zonemod/addons/sourcemod/scripting"
SM_SCRIPTING="${ROOT}/SourceMod/sourcemod/addons/sourcemod/scripting"
SPCOMP="${SM_SCRIPTING}/spcomp.exe"

if [[ ! -x "${SPCOMP}" && ! -f "${SPCOMP}" ]]; then
    echo "build-plugins: spcomp.exe not found at ${SPCOMP}" >&2
    exit 1
fi

if ! command -v wine >/dev/null 2>&1; then
    echo "build-plugins: 'wine' is required to run spcomp.exe; install it on the runner." >&2
    exit 1
fi

# Mirror the PowerShell logic: copy any .sp/.inc/etc from bizzymod and zonemod
# scripting trees into the SM scripting tree, BUT only if not already present
# (SM's own files win on collision).
merge_into_sm() {
    local src="$1" label="$2"
    [[ -d "${src}" ]] || { echo "build-plugins: skipping ${label} (no ${src})"; return 0; }
    echo "build-plugins: merging ${label} into SM scripting tree (skip-existing)"
    # -n = no-clobber. Quiet on collisions.
    cp -an "${src}/." "${SM_SCRIPTING}/"
}

merge_into_sm "${BIZZY_SCRIPTING}" "bizzymod scripting"
merge_into_sm "${ZONE_SCRIPTING}"  "zonemod scripting"

cd "${SM_SCRIPTING}"

# Silence wine's first-run chatter.
export WINEDEBUG="${WINEDEBUG:-fixme-all,err-all}"
export WINEPREFIX="${WINEPREFIX:-/tmp/wineprefix-spcomp}"
mkdir -p "${WINEPREFIX}"

failed=0
built=0

for smx in "${BIZZY_PLUGINS}"/*.smx; do
    [[ -e "${smx}" ]] || { echo "build-plugins: no .smx in ${BIZZY_PLUGINS}; nothing to do."; break; }
    base="$(basename "${smx}" .smx)"
    sp="${SM_SCRIPTING}/${base}.sp"

    if [[ ! -f "${sp}" ]]; then
        echo "  skip: ${base}.smx has no matching ${base}.sp in merged scripting tree"
        continue
    fi

    echo "  build: ${base}.sp"
    if ! wine "${SPCOMP}" "${base}.sp" >/tmp/spcomp.${base}.log 2>&1; then
        echo "    FAILED (last 30 lines):"
        tail -n 30 "/tmp/spcomp.${base}.log" | sed 's/^/      /'
        failed=$((failed + 1))
        continue
    fi

    out="${SM_SCRIPTING}/${base}.smx"
    if [[ ! -f "${out}" ]]; then
        echo "    FAILED: spcomp returned 0 but ${out} not produced"
        failed=$((failed + 1))
        continue
    fi

    cp -f "${out}" "${smx}"
    built=$((built + 1))
done

echo "build-plugins: ${built} built, ${failed} failed."
if [[ "${failed}" -gt 0 ]]; then
    echo "build-plugins: failed plugin(s) keep their existing .smx in the repo as fallback."
    echo "build-plugins: set BUILD_STRICT=1 to make any compile failure fatal."
    if [[ "${BUILD_STRICT:-0}" == "1" ]]; then
        exit 1
    fi
fi
# Sanity: refuse to ship if NOTHING built — that's a real toolchain failure.
if [[ "${built}" -eq 0 && "${failed}" -gt 0 ]]; then
    echo "build-plugins: 0 successful builds — toolchain is broken; aborting."
    exit 1
fi
