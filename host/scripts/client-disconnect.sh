#!/bin/bash
# OpenVPN client-disconnect hook.
#
# OpenVPN runs this once per client disconnect with the session details exported
# as environment variables (common_name, trusted_ip, time_duration). The script
# appends a record to a small JSON store that the openvpn-ui Map View reads to
# draw faded "recently disconnected" markers. Records older than RETENTION_SECS
# are pruned on every write so the file stays small and self-expiring.
#
# Registered from server.conf via:
#   script-security 2
#   client-disconnect /opt/scripts/client-disconnect.sh
#
# Wired automatically by host/setup.sh (setup_disconnect_hook).

set -euo pipefail

STORE="${RECENT_DISCONNECTS_PATH:-/opt/scripts/recent-disconnects.json}"
LOCK="${STORE}.lock"
RETENTION_SECS=3600  # keep the last hour; must match recentWindow in mapview.go

cn="${common_name:-}"
ip="${trusted_ip:-${untrusted_ip:-}}"
dur_secs="${time_duration:-0}"

# Nothing useful to record without a CN and a public IP.
[[ -z "$cn" || -z "$ip" ]] && exit 0

now="$(date +%s)"

# Human-readable duration matching Go's time.Duration.String() for the cases we hit
# (e.g. "11s", "44m59s", "3h25m19s").
h=$(( dur_secs / 3600 ))
m=$(( (dur_secs % 3600) / 60 ))
s=$(( dur_secs % 60 ))
if   (( h > 0 )); then dur="${h}h${m}m${s}s"
elif (( m > 0 )); then dur="${m}m${s}s"
else                   dur="${s}s"
fi

cutoff=$(( now - RETENTION_SECS ))
record="{\"cn\":\"${cn}\",\"ip\":\"${ip}\",\"disconnect_epoch\":${now},\"duration\":\"${dur}\"}"

# Serialize concurrent disconnects; prune expired entries, then append the new one.
# flock is present on the Linux server (util-linux); degrade gracefully if absent.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock 9
fi

tmp="${STORE}.tmp.$$"
if command -v jq >/dev/null 2>&1 && [[ -s "$STORE" ]]; then
  jq -c --argjson cutoff "$cutoff" --argjson rec "$record" \
     '(. // []) | map(select(.disconnect_epoch >= $cutoff)) + [$rec]' \
     "$STORE" > "$tmp" 2>/dev/null || echo "[${record}]" > "$tmp"
else
  # No jq (or empty/missing store): start fresh. Pruning still happens on the
  # controller side via the 1-hour window, so a rare reset just drops history.
  echo "[${record}]" > "$tmp"
fi

mv "$tmp" "$STORE"
chmod 644 "$STORE" 2>/dev/null || true

exit 0
