#!/usr/bin/env bash
#
# setup-storage-oss.sh
# Installs ossutil and writes /root/.ossutilconfig for the openvpn-ui Alibaba
# Cloud OSS storage backend. Called by host/setup.sh when StorageProvider=oss.
#
# Usage:
#   sudo setup-storage-oss.sh <access-key-id> <access-key-secret> <endpoint>

set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
[[ $# -eq 3 ]] || { echo "Usage: $0 <access-key-id> <access-key-secret> <endpoint>" >&2; exit 1; }

OSS_KEY_ID="$1"
OSS_KEY_SECRET="$2"
OSS_ENDPOINT="$3"

if ! command -v ossutil &>/dev/null; then
  echo "[INFO] Installing ossutil..."
  curl -fsSL https://gosspublic.alicdn.com/ossutil/install.sh -o /tmp/ossutil-install.sh
  bash /tmp/ossutil-install.sh < /dev/null > /dev/null 2>&1
  rm -f /tmp/ossutil-install.sh
  echo "[INFO] ossutil installed."
else
  echo "[INFO] ossutil already installed."
fi

cat > /root/.ossutilconfig <<OSSCONF
[Credentials]
language=EN
accessKeyID=${OSS_KEY_ID}
accessKeySecret=${OSS_KEY_SECRET}
endpoint=${OSS_ENDPOINT}
OSSCONF
chmod 600 /root/.ossutilconfig
echo "[INFO] OSS credentials written to /root/.ossutilconfig"
