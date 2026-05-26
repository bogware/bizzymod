#!/usr/bin/env bash
# replace-tokens.sh — substitute #{Token}# placeholders across **/*.cfg.
#
# Source of token names: the ADO release export at .cicd/AzureDevOpsReleaseExport.json.
# Values are read from the process environment (the GH Actions step injects them).
#
# Unset tokens are left as warnings (mirroring the ADO "actionOnMissing: warn" setting),
# not failures. Run with --strict to fail on any unset token.

set -euo pipefail

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

# Token name -> env var name (env vars are uppercase by convention).
# The "key" on the left is what appears between #{ }# in the cfg.
TOKENS=(
    "Server_Name=SERVER_NAME"
    "RCON_Pass=RCON_PASS"
    "HostBanner=HOST_BANNER"
    "HostMOTD=HOST_MOTD"
    "l4dstats_DB=L4DSTATS_DB"
    "l4dstats_DB_IP=L4DSTATS_DB_IP"
    "l4dstats_Port=L4DSTATS_PORT"
    "l4dstats_User=L4DSTATS_USER"
    "l4dstats_Pass=L4DSTATS_PASS"
    "SourceBans_DB=SOURCEBANS_DB"
    "SourceBans_DB_IP=SOURCEBANS_DB_IP"
    "SourceBans_Port=SOURCEBANS_PORT"
    "SourceBans_User=SOURCEBANS_USER"
    "SourceBans_Pass=SOURCEBANS_PASS"
    "BizzymodStats_DB=BIZZYMOD_STATS_DB"
    "BizzymodStats_DB_IP=BIZZYMOD_STATS_DB_IP"
    "BizzymodStats_Port=BIZZYMOD_STATS_PORT"
    "BizzymodStats_User=BIZZYMOD_STATS_USER"
    "BizzymodStats_Pass=BIZZYMOD_STATS_PASS"
    "userName=SRCDS_USER"
    "RemoteTargetFolder=REMOTE_TARGET_FOLDER"
    "initPath=INIT_PATH"
)

ROOT="${1:-.}"
[[ "${ROOT}" == "--strict" ]] && ROOT="."

mapfile -t CFG_FILES < <(find "${ROOT}" -type f -name '*.cfg' -not -path './SourceMod/*' -not -path './.git/*')
if [[ "${#CFG_FILES[@]}" -eq 0 ]]; then
    echo "replace-tokens: no .cfg files under ${ROOT}; nothing to do."
    exit 0
fi

echo "replace-tokens: scanning ${#CFG_FILES[@]} cfg files under ${ROOT}"

missing=0
for entry in "${TOKENS[@]}"; do
    token="${entry%%=*}"
    var="${entry##*=}"
    value="${!var:-}"

    if [[ -z "${value}" ]]; then
        if grep -qlF "#{${token}}#" "${CFG_FILES[@]}" 2>/dev/null; then
            echo "  warn: token #{${token}}# referenced but env \$${var} is empty"
            missing=$((missing + 1))
        fi
        continue
    fi

    # Escape sed delimiter | in value (rare for these tokens, but safe).
    safe="${value//|/\\|}"
    # \n in value would break sed; not expected for these tokens. Refuse if present.
    if [[ "${safe}" == *$'\n'* ]]; then
        echo "  error: \$${var} contains a newline; refusing." >&2
        exit 1
    fi

    # In-place substitution.
    sed -i "s|#{${token}}#|${safe}|g" "${CFG_FILES[@]}"
done

if [[ "${missing}" -gt 0 && "${STRICT}" -eq 1 ]]; then
    echo "replace-tokens: ${missing} token(s) unset in --strict mode; failing." >&2
    exit 1
fi

# Sanity: warn about any #{...}# that survived (might be unknown tokens).
remaining="$(grep -rohE '#\{[A-Za-z0-9_]+\}#' "${CFG_FILES[@]}" 2>/dev/null | sort -u || true)"
if [[ -n "${remaining}" ]]; then
    echo "replace-tokens: unresolved placeholders remain:"
    echo "${remaining}" | sed 's/^/  /'
fi

echo "replace-tokens: done."
