#!/bin/bash
# Removes a revoked certificate from the index and regenerates the .ovpn file.
# Refuses to act on a certificate that is still valid — revoke it first.
#
# Called by openvpn-ui when deleting a revoked client.
# Adapted for angristan/openvpn-install layout with tls-crypt-v2.
#
# Usage: rmcert.sh <name> <serial>

set -e

CERT_NAME="$1"
CERT_SERIAL="$2"

EASY_RSA="/usr/share/easy-rsa"
OPENVPN_DIR="/etc/openvpn"
OVPN_FILE_PATH="${OPENVPN_DIR}/clients/${CERT_NAME}.ovpn"
INDEX="${EASY_RSA}/pki/index.txt"

[[ -n "$CERT_NAME" ]]   || { echo "Usage: rmcert.sh <name> <serial>" >&2; exit 1; }
[[ -n "$CERT_SERIAL" ]] || { echo "Usage: rmcert.sh <name> <serial>" >&2; exit 1; }

STATUS_CH=$(grep -e "${CERT_NAME}$" -e "${CERT_NAME}/" "${INDEX}" \
  | awk '{print $1}' | tr -d '\n')

if [[ "$STATUS_CH" == "V" ]]; then
  echo "Certificate is still VALID — revoke it before removing." >&2
  exit 1
fi

if [[ $(grep -c "/CN=${CERT_NAME}/" "${INDEX}") -eq 2 ]]; then
  # Renewed cert: remove old serial entry, regenerate .ovpn from current cert
  sed -i'.bak' "/${CERT_SERIAL}/d" "${INDEX}"
  rm -f "${OVPN_FILE_PATH}"
  CA="$(cat "${EASY_RSA}/pki/ca.crt")"
  CERT="$(cat "${EASY_RSA}/pki/issued/${CERT_NAME}.crt" \
    | grep -zEo -e '-----BEGIN CERTIFICATE-----(\n|.)*-----END CERTIFICATE-----' \
    | tr -d '\0')"
  KEY="$(cat "${EASY_RSA}/pki/private/${CERT_NAME}.key")"
  TLS_CRYPT_V2="$(cat "${OPENVPN_DIR}/tls-crypt-v2.key")"
  cat > "${OVPN_FILE_PATH}" <<OVPN_EOF
$(cat "${OPENVPN_DIR}/client-template-clean.txt")
<ca>
${CA}
</ca>
<cert>
${CERT}
</cert>
<key>
${KEY}
</key>
<tls-crypt-v2>
${TLS_CRYPT_V2}
</tls-crypt-v2>
OVPN_EOF
  echo "New .ovpn generated."
else
  rm -f "${OVPN_FILE_PATH}"
  sed -i'.bak' "/${CERT_SERIAL}/d" "${INDEX}"
  echo "Certificate removed."
fi
