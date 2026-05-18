#!/bin/bash
# Compresses the rolling OpenVPN session log and stores the archive in the
# configured backend. StorageProvider and per-provider fields are read from
# /opt/openvpn-ui/conf/app.conf at runtime.
#
# Usage:
#   ovpn-log-rotate.sh          Rotate only if the master log is >= 10 MB
#   ovpn-log-rotate.sh --eod    Force rotation if the master log is non-empty

set -euo pipefail

APP_CONF="/opt/openvpn-ui/conf/app.conf"
MASTER_LOG="/opt/scripts/ovpn-master.log"
MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB
DEFAULT_LOCAL_LOG_DIR="/var/log/openvpn-ui/archives"
DEFAULT_OSS_ENDPOINT="oss-me-central-1.aliyuncs.com"

_conf() {
  grep -E "^${1}[[:space:]]*=" "$APP_CONF" 2>/dev/null \
    | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '"' | xargs
}

STORAGE_PROVIDER="$(_conf StorageProvider)"
LOCAL_LOG_DIR="$(_conf LocalLogDir)"
OSS_BUCKET="$(_conf OSSLogBucket)"
OSS_ENDPOINT="$(_conf OSSEndpoint)"
S3_BUCKET="$(_conf S3LogBucket)"
S3_REGION="$(_conf S3Region)"
GCS_BUCKET="$(_conf GCSLogBucket)"
GCS_KEY_FILE="$(_conf GCSServiceAccountKeyFile)"

# Backwards compatibility: if StorageProvider is unset but OSSLogBucket is set,
# behave like the old OSS-only rotation script.
if [[ -z "$STORAGE_PROVIDER" ]]; then
  if [[ -n "$OSS_BUCKET" ]]; then STORAGE_PROVIDER="oss"; else STORAGE_PROVIDER="local"; fi
fi
[[ -z "$LOCAL_LOG_DIR" ]] && LOCAL_LOG_DIR="$DEFAULT_LOCAL_LOG_DIR"
[[ -z "$OSS_ENDPOINT" ]] && OSS_ENDPOINT="$DEFAULT_OSS_ENDPOINT"

require_cmd() {
  local bin="$1" provider="$2" setup_script="$3"
  command -v "$bin" >/dev/null 2>&1 && return 0
  cat >&2 <<MSG
[ovpn-log-rotate] StorageProvider=${provider} but '${bin}' is not installed on this host.
Run: sudo /opt/scripts/${setup_script} ...   (see host/setup.sh for arguments)
Master log NOT truncated.
MSG
  return 1
}

store_local() {
  local archive="$1"
  mkdir -p "$LOCAL_LOG_DIR"
  mv "$archive" "${LOCAL_LOG_DIR}/$(basename "$archive")"
}

store_oss() {
  local archive="$1"
  if [[ -z "$OSS_BUCKET" ]]; then
    echo "OSSLogBucket not set in ${APP_CONF} — skipping upload." >&2
    return 1
  fi
  require_cmd ossutil oss setup-storage-oss.sh || return 1
  ossutil cp "$archive" "oss://${OSS_BUCKET}/$(basename "$archive")" \
    --endpoint "$OSS_ENDPOINT"
  rm -f "$archive"
}

store_s3() {
  local archive="$1"
  if [[ -z "$S3_BUCKET" || -z "$S3_REGION" ]]; then
    echo "S3LogBucket/S3Region not set in ${APP_CONF} — skipping upload." >&2
    return 1
  fi
  require_cmd aws s3 setup-storage-s3.sh || return 1
  AWS_REGION="$S3_REGION" \
    aws s3 cp "$archive" "s3://${S3_BUCKET}/$(basename "$archive")" \
    --only-show-errors
  rm -f "$archive"
}

store_gcs() {
  local archive="$1"
  if [[ -z "$GCS_BUCKET" ]]; then
    echo "GCSLogBucket not set in ${APP_CONF} — skipping upload." >&2
    return 1
  fi
  require_cmd gcloud gcs setup-storage-gcs.sh || return 1
  # gcloud reads GOOGLE_APPLICATION_CREDENTIALS for service-account auth.
  if [[ -n "$GCS_KEY_FILE" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS="$GCS_KEY_FILE"
  fi
  gcloud storage cp "$archive" "gs://${GCS_BUCKET}/$(basename "$archive")" \
    --quiet
  rm -f "$archive"
}

rotate() {
  local timestamp archive
  timestamp=$(date -u +"%Y-%m-%d-%H%M%S")
  archive="/tmp/openvpn-logs-${timestamp}.log.gz"
  gzip -c "$MASTER_LOG" > "$archive"

  case "$STORAGE_PROVIDER" in
    local) store_local "$archive" ;;
    oss)   store_oss   "$archive" ;;
    s3)    store_s3    "$archive" ;;
    gcs)   store_gcs   "$archive" ;;
    *)
      rm -f "$archive"
      echo "Unknown StorageProvider '${STORAGE_PROVIDER}' — master log NOT truncated." >&2
      exit 56
      ;;
  esac \
    || { echo "Archive store failed — master log NOT truncated." >&2; exit 57; }

  : > "$MASTER_LOG"
  echo "Rotated: openvpn-logs-${timestamp}.log.gz (provider=${STORAGE_PROVIDER})"
}

CURRENT_SIZE=$(wc -c < "$MASTER_LOG" 2>/dev/null || echo 0)
if [[ "$CURRENT_SIZE" -ge "$MAX_BYTES" ]]; then
  rotate
fi

if [[ "${1:-}" == "--eod" ]]; then
  [[ -s "$MASTER_LOG" ]] && rotate
fi
