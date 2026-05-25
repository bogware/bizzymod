#!/usr/bin/env bash
# build-plugins.sh — compile all Bizzymod SourcePawn plugins.
#
# Compile root is SourceMod fetched fresh per build by the workflow (see
# deploy.yml step "Download SourceMod compile root"). The version matches
# zonemod's runtime so .smx ABI is identical at compile-time and runtime.
#
# Inputs:
#   ./addons/sourcemod/plugins/bizzymod/*.smx        build manifest (basename → .sp to compile)
#   ./addons/sourcemod/scripting/                    bizzymod .sp + includes (including multicolors/)
#   ./zonemod/addons/sourcemod/scripting/            zonemod source repo (current includes, left4dhooks.inc, etc.)
#   ${SM_COMPILE_ROOT}/addons/sourcemod/scripting/   SourceMod scripting tree with Linux spcomp + base includes
#
# Both bizzymod and zonemod scripting trees are merged INTO the SM scripting
# tree (skip-existing — SM's own files win on collision). spcomp is then run
# from that merged directory so #include <foo> resolves correctly.
#
# Outputs:
#   compiled .smx written back over ./addons/sourcemod/plugins/bizzymod/*.smx
#
# Required env: SM_COMPILE_ROOT must point at an extracted SourceMod tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIZZY_PLUGINS="${ROOT}/addons/sourcemod/plugins/bizzymod"
BIZZY_SCRIPTING="${ROOT}/addons/sourcemod/scripting"
ZONE_SCRIPTING="${ROOT}/zonemod/addons/sourcemod/scripting"

# Default to repo-local _sm_compile_root if env not set (lets you run locally).
SM_COMPILE_ROOT="${SM_COMPILE_ROOT:-${ROOT}/_sm_compile_root}"
SM_SCRIPTING="${SM_COMPILE_ROOT}/addons/sourcemod/scripting"
SPCOMP="${SM_SCRIPTING}/spcomp"

if [[ ! -d "${SM_SCRIPTING}" ]]; then
    echo "build-plugins: SourceMod scripting tree not found at ${SM_SCRIPTING}" >&2
    echo "build-plugins: did the workflow's 'Download SourceMod' step run?" >&2
    exit 1
fi

if [[ ! -x "${SPCOMP}" ]]; then
    if [[ -f "${SPCOMP}" ]]; then
        chmod +x "${SPCOMP}"
    else
        echo "build-plugins: spcomp not found at ${SPCOMP}" >&2
        exit 1
    fi
fi

echo "build-plugins: spcomp version:"
"${SPCOMP}" -h 2>&1 | head -2 || true

# Merge bizzymod and zonemod scripting trees into the SM scripting tree.
# -n = no-clobber. Quiet on collisions; SM's own files win.
merge_into_sm() {
    local src="$1" label="$2"
    [[ -d "${src}" ]] || { echo "build-plugins: skipping ${label} (no ${src})"; return 0; }
    echo "build-plugins: merging ${label} into SM scripting tree (skip-existing)"
    cp -an "${src}/." "${SM_SCRIPTING}/"
}

merge_into_sm "${BIZZY_SCRIPTING}" "bizzymod scripting"
merge_into_sm "${ZONE_SCRIPTING}"  "zonemod scripting"

cd "${SM_SCRIPTING}"

failed=0
built=0
fail_list=()

for smx in "${BIZZY_PLUGINS}"/*.smx; do
    [[ -e "${smx}" ]] || { echo "build-plugins: no .smx in ${BIZZY_PLUGINS}; nothing to do."; break; }
    base="$(basename "${smx}" .smx)"
    sp="${SM_SCRIPTING}/${base}.sp"

    if [[ ! -f "${sp}" ]]; then
        echo "  skip: ${base}.smx has no matching ${base}.sp in merged scripting tree"
        continue
    fi

    echo "  build: ${base}.sp"
    if ! "${SPCOMP}" "${base}.sp" >/tmp/spcomp.${base}.log 2>&1; then
        echo "    FAILED (last 30 lines):"
        tail -n 30 "/tmp/spcomp.${base}.log" | sed 's/^/      /'
        failed=$((failed + 1))
        fail_list+=("${base}")
        continue
    fi

    out="${SM_SCRIPTING}/${base}.smx"
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
