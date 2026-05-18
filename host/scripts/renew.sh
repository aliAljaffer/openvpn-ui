#!/bin/bash
# Renews an expiring client certificate.
# Called by openvpn-ui when renewing a client.
# Adapted for angristan/openvpn-install layout.
#
# Usage: renew.sh <name> [<static-ip>] [<serial>]

set -e

CERT_NAME="$1"
CERT_IP="${2:-}"
TFA_NAME="${TFA_NAME:-none}"

EASY_RSA="/usr/share/easy-rsa"

[[ -n "$CERT_NAME" ]] || { echo "Usage: renew.sh <name> [<static-ip>] [<serial>]" >&2; exit 78; }

export EASYRSA_BATCH=1
cd "${EASY_RSA}"
./easyrsa renew "${CERT_NAME}"

sed -i'.bak' "$ s/$/\/name=${CERT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" \
  "${EASY_RSA}/pki/index.txt"

echo "Done."
