#!/bin/bash
# ============================================================================
# imgctl Web GUI - snapshot producer (runs as root via imgcatalog-refresh.timer)
# ============================================================================
# Runs `imgctl get all -o json`, validates it, injects the Harbor registry host
# and cluster name, then ATOMICALLY replaces the snapshot the web server reads.
# On ANY failure it leaves the previous (last-good) snapshot untouched, so the
# portal degrades gracefully (serves stale data + a banner) instead of breaking.
#
# Reads /etc/imgctl/imgctl.conf (root-only; holds Harbor creds) so the
# unprivileged web tier never needs to.
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Organization: Global Info Ventures Pvt Ltd
# ============================================================================
set -o pipefail

CONF="${IMGCTL_CONF:-/etc/imgctl/imgctl.conf}"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"

IMGCTL_BIN="${IMGCTL_BIN:-/usr/local/bin/imgctl}"
SNAPSHOT="${WEB_SNAPSHOT_PATH:-/var/lib/imgcatalog/all.json}"
SNAP_DIR="$(dirname "$SNAPSHOT")"

log() { echo "[imgcatalog-refresh] $*" >&2; }

# Derive the Harbor registry host used as the pull prefix for custom images
# (e.g. vips-headnode:9443). Override with WEB_HARBOR_REGISTRY_HOST in the conf.
HOST="${WEB_HARBOR_REGISTRY_HOST:-}"
if [[ -z "$HOST" && -n "${HARBOR_URL:-}" ]]; then
    HOST="${HARBOR_URL#*://}"   # strip scheme
    HOST="${HOST%%/*}"          # strip any trailing path
fi
CLUSTER="${CLUSTER_NAME:-}"
# Optional config-driven display text (keeps the UI free of hardcoded names).
TITLE="${WEB_SITE_TITLE:-}"
SUBTITLE="${WEB_SITE_SUBTITLE:-}"
LABEL_HARBOR="${WEB_LABEL_HARBOR:-}"
LABEL_NODE="${WEB_LABEL_NODE:-}"

command -v jq >/dev/null 2>&1 || { log "jq not found; aborting (last-good kept)"; exit 1; }
[[ -x "$IMGCTL_BIN" ]] || { log "imgctl not found at $IMGCTL_BIN (last-good kept)"; exit 1; }

mkdir -p "$SNAP_DIR" || { log "cannot create $SNAP_DIR"; exit 1; }

RAW="$(mktemp "${SNAPSHOT}.raw.XXXXXX")"  || { log "mktemp failed"; exit 1; }
FINAL="$(mktemp "${SNAPSHOT}.new.XXXXXX")" || { rm -f "$RAW"; log "mktemp failed"; exit 1; }
trap 'rm -f "$RAW" "$FINAL" 2>/dev/null' EXIT

# 1) Produce (imgctl stderr/logs flow to journald + its own root-only log).
if ! "$IMGCTL_BIN" get all -o json >"$RAW"; then
    log "imgctl exited non-zero; keeping last-good snapshot"
    exit 1
fi

# 2) Validate: parses as JSON and has the expected top-level shape.
if ! jq -e 'type == "object" and (has("harbor_images") or has("comparison"))' "$RAW" >/dev/null 2>&1; then
    log "imgctl output is not valid/expected JSON; keeping last-good snapshot"
    exit 1
fi
SZ="$(stat -c %s "$RAW" 2>/dev/null || echo 0)"
[[ "$SZ" -ge 2 ]] || { log "imgctl output empty; keeping last-good snapshot"; exit 1; }

# 3) Inject harbor_host + cluster_name for the web tier.
if ! jq --arg h "$HOST" --arg c "$CLUSTER" \
        '. + {harbor_host: $h, cluster_name: $c}' "$RAW" >"$FINAL" 2>/dev/null; then
    log "failed to annotate snapshot; keeping last-good snapshot"
    exit 1
fi

# 4) Atomic publish: world-readable (unprivileged web user reads it), then rename.
chmod 0644 "$FINAL"
sync "$FINAL" 2>/dev/null || true
if ! mv -f "$FINAL" "$SNAPSHOT"; then
    log "atomic replace failed; keeping last-good snapshot"
    exit 1
fi

log "snapshot updated: $SNAPSHOT (harbor_host='${HOST}', cluster='${CLUSTER}')"
exit 0
