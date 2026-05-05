#!/bin/bash
# Compresses the rolling OpenVPN session log and uploads it to Alibaba Cloud OSS.
# Reads OSSLogBucket and OSSEndpoint from /opt/openvpn-ui/conf/app.conf at runtime.
#
# Usage:
#   ovpn-log-rotate.sh          Rotate only if the master log is >= 10 MB
#   ovpn-log-rotate.sh --eod    Force rotation if the master log is non-empty

set -euo pipefail

APP_CONF="/opt/openvpn-ui/conf/app.conf"
MASTER_LOG="/opt/scripts/ovpn-master.log"
MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB

_conf() {
  grep -E "^${1}[[:space:]]*=" "$APP_CONF" 2>/dev/null \
    | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '"' | xargs
}

OSS_BUCKET="$(_conf OSSLogBucket)"
OSS_ENDPOINT="$(_conf OSSEndpoint)"

if [[ -z "$OSS_BUCKET" ]]; then
  echo "OSSLogBucket not set in ${APP_CONF} — skipping upload." >&2
  exit 0
fi

[[ -z "$OSS_ENDPOINT" ]] && OSS_ENDPOINT="oss-me-central-1.aliyuncs.com"

rotate() {
  local timestamp archive
  timestamp=$(date -u +"%Y-%m-%d-%H%M%S")
  archive="/tmp/openvpn-logs-${timestamp}.log.gz"
  gzip -c "$MASTER_LOG" > "$archive"
  if ossutil cp "$archive" "oss://${OSS_BUCKET}/openvpn-logs-${timestamp}.log.gz" \
      --endpoint "$OSS_ENDPOINT"; then
    : > "$MASTER_LOG"
    rm -f "$archive"
    echo "Rotated: openvpn-logs-${timestamp}.log.gz"
  else
    rm -f "$archive"
    echo "OSS upload failed — master log NOT truncated." >&2
    exit 1
  fi
}

CURRENT_SIZE=$(stat -c%s "$MASTER_LOG" 2>/dev/null || echo 0)
if [[ "$CURRENT_SIZE" -ge "$MAX_BYTES" ]]; then
  rotate
fi

if [[ "${1:-}" == "--eod" ]]; then
  [[ -s "$MASTER_LOG" ]] && rotate
fi
