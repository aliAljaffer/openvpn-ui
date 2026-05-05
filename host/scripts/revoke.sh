#!/bin/bash
# Revokes a client certificate and schedules an OpenVPN restart at 23:59.
# The deferred restart disconnects the revoked client at end of day without
# interrupting other active sessions mid-day.
#
# Called by openvpn-ui when revoking a client.
# Adapted for angristan/openvpn-install layout.
#
# Usage: revoke.sh <name> <serial>

set -e

CERT_NAME="$1"
CERT_SERIAL="$2"

EASY_RSA="/usr/share/easy-rsa"
OPENVPN_DIR="/etc/openvpn"
INDEX="${EASY_RSA}/pki/index.txt"
OVPN_FILE_PATH="${OPENVPN_DIR}/clients/${CERT_NAME}.ovpn"

[[ -n "$CERT_NAME" ]]   || { echo "Usage: revoke.sh <name> <serial>" >&2; exit 1; }
[[ -n "$CERT_SERIAL" ]] || { echo "Usage: revoke.sh <name> <serial>" >&2; exit 1; }

export EASYRSA_BATCH=1

if [[ $(grep -c "/CN=${CERT_NAME}/" "${INDEX}") -eq 2 ]]; then
  FIRST_SERIAL=$(grep "/CN=${CERT_NAME}/" "${INDEX}" | head -1 | awk '{print $3}')
  if [[ "$FIRST_SERIAL" == "$CERT_SERIAL" ]]; then
    sed -i'.bak' "/${CERT_SERIAL}/s/\/name=${CERT_NAME}.*//" "${INDEX}"
    cd "${EASY_RSA}"
    ./easyrsa revoke-renewed "${CERT_NAME}"
    sed -i'.bak' "/${CERT_SERIAL}/d" "${INDEX}"
    rm -f "${OVPN_FILE_PATH}"
    ./easyrsa gen-crl
    chmod +r "${EASY_RSA}/pki/crl.pem"
  else
    cd "${EASY_RSA}"
    mv "${EASY_RSA}/pki/renewed/issued/${CERT_NAME}.crt" \
       "${EASY_RSA}/pki/issued/${CERT_NAME}.crt"
    rm -f "${EASY_RSA}/pki/inline/${CERT_NAME}.inline"
    sed -i'.bak' "/${CERT_SERIAL}/d" "${INDEX}"
    ./easyrsa gen-crl
    chmod +r "${EASY_RSA}/pki/crl.pem"
  fi
else
  if [[ -f "${EASY_RSA}/pki/issued/${CERT_NAME}.crt" ]]; then
    sed -i'.bak' "/${CERT_SERIAL}/s/\/name=${CERT_NAME}.*//" "${INDEX}"
    cd "${EASY_RSA}"
    ./easyrsa revoke "${CERT_NAME}"
    ./easyrsa gen-crl
    chmod +r "${EASY_RSA}/pki/crl.pem"
    sed -i'.bak' "/${CERT_SERIAL}/ s/$/\/name=${CERT_NAME}\/LocalIP=\/2FAName=none/" "${INDEX}"
  else
    # .crt file missing — mark revoked directly in index.txt
    REVDATE=$(date -u +"%y%m%d%H%M%SZ")
    cp "${INDEX}" "${INDEX}.bak"
    awk -v serial="${CERT_SERIAL}" -v revdate="${REVDATE}" -F"\t" '
      BEGIN { OFS="\t" }
      $4 == serial && $1 == "V" { $1 = "R"; $3 = revdate }
      { print }
    ' "${INDEX}.bak" > "${INDEX}"
    cd "${EASY_RSA}"
    ./easyrsa gen-crl
    chmod +r "${EASY_RSA}/pki/crl.pem"
  fi
fi

# Schedule a 23:59 restart to disconnect the revoked client.
# Touching the flag twice is harmless — cron removes it after restarting once.
RESTART_FLAG="/run/openvpn-restart-pending"
if [[ ! -f "$RESTART_FLAG" ]]; then
  touch "$RESTART_FLAG"
  echo "Done. OpenVPN restart scheduled for 23:59 — revoked client will be disconnected then."
else
  echo "Done. Restart already scheduled for 23:59."
fi
