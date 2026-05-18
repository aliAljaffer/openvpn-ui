#!/usr/bin/env bash
#
# setup-storage-gcs.sh
# Installs the Google Cloud SDK (gcloud) and stages the service-account key
# file for the openvpn-ui GCP Cloud Storage backend. Called by host/setup.sh
# when StorageProvider=gcs. The key file is also mounted read-only into the
# openvpn-ui container so the Go SDK can authenticate via GCSServiceAccountKeyFile.
#
# Usage:
#   sudo setup-storage-gcs.sh <path-to-service-account-key.json> <dest-key-path>
#
# Both paths are required. <dest-key-path> is where the key will live on the
# host (e.g. /etc/openvpn-ui/gcs-sa-key.json) and what gets bind-mounted into
# the container at the same path.

set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
[[ $# -eq 2 ]] || { echo "Usage: $0 <src-key.json> <dest-key-path>" >&2; exit 1; }

SRC_KEY="$1"
DEST_KEY="$2"

[[ -f "$SRC_KEY" ]] || { echo "Service account key not found: ${SRC_KEY}" >&2; exit 1; }

if ! command -v gcloud &>/dev/null; then
  echo "[INFO] Installing Google Cloud SDK..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq --no-install-recommends \
    apt-transport-https ca-certificates gnupg curl >/dev/null 2>&1
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq --no-install-recommends google-cloud-cli >/dev/null 2>&1
  echo "[INFO] gcloud installed."
else
  echo "[INFO] gcloud already installed."
fi

mkdir -p "$(dirname "$DEST_KEY")"
install -m 600 "$SRC_KEY" "$DEST_KEY"
echo "[INFO] Service account key written to ${DEST_KEY}"

echo "[INFO] Activating service account for the host-side rotation cron..."
gcloud auth activate-service-account --key-file="$DEST_KEY" --quiet >/dev/null
echo "[INFO] gcloud service account active."
