#!/bin/bash
# Generates a client certificate and .ovpn config file.
# Called by openvpn-ui when creating a new VPN client.
# Adapted for angristan/openvpn-install layout with tls-crypt-v2.
#
# Usage: genclient.sh <name> [<static-ip>] [<password>]

set -e

CERT_NAME="$1"
CERT_IP="${2:-}"
CERT_PASS="${3:-}"

EASY_RSA="/usr/share/easy-rsa"
OPENVPN_DIR="/etc/openvpn"
# Save to OVClientsDir from app.conf, defaulting to /root
OV_CLIENTS_DIR="$(grep -E "^OVClientsDir" /opt/openvpn-ui/conf/app.conf 2>/dev/null \
  | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '"' | xargs)"
OV_CLIENTS_DIR="${OV_CLIENTS_DIR:-/root}"
OVPN_FILE_PATH="${OV_CLIENTS_DIR}/${CERT_NAME}.ovpn"
CLIENT_TEMPLATE="${OPENVPN_DIR}/client-template-clean.txt"

if [[ -z "$CERT_NAME" ]]; then
  echo "Usage: genclient.sh <name> [<static-ip>] [<password>]" >&2
  exit 1
fi
if [[ -f "$OVPN_FILE_PATH" ]]; then
  echo "Client ${CERT_NAME} already exists at ${OVPN_FILE_PATH}." >&2
  exit 1
fi
if [[ ! -f "$CLIENT_TEMPLATE" ]]; then
  echo "client-template-clean.txt not found at ${CLIENT_TEMPLATE}." >&2
  echo "Re-run the openvpn-ui setup script to create it." >&2
  exit 1
fi

export EASYRSA_BATCH=1
TFA_NAME="${TFA_NAME:-none}"

# Patch openssl config for easy-rsa 3.1.x compatibility
sed -i '/serialNumber_default/d' "${EASY_RSA}/openssl-easyrsa.cnf" 2>/dev/null || true

echo "Generating certificate for ${CERT_NAME}..."
cd "${EASY_RSA}"

if [[ -z "$CERT_PASS" ]]; then
  ./easyrsa --batch \
    --req-cn="${CERT_NAME}" \
    ${EASYRSA_CERT_EXPIRE:+--days="${EASYRSA_CERT_EXPIRE}"} \
    ${EASYRSA_REQ_EMAIL:+--req-email="${EASYRSA_REQ_EMAIL}"} \
    gen-req "${CERT_NAME}" nopass
else
  (echo -e '\n') | ./easyrsa --batch \
    --req-cn="${CERT_NAME}" \
    ${EASYRSA_CERT_EXPIRE:+--days="${EASYRSA_CERT_EXPIRE}"} \
    ${EASYRSA_REQ_EMAIL:+--req-email="${EASYRSA_REQ_EMAIL}"} \
    --passin=pass:"${CERT_PASS}" \
    --passout=pass:"${CERT_PASS}" \
    gen-req "${CERT_NAME}"
fi

./easyrsa sign-req client "${CERT_NAME}"

# Append name/IP to index.txt — openvpn-ui reads these extra fields
sed -i'.bak' "$ s/$/\/name=${CERT_NAME}\/LocalIP=${CERT_IP}\/2FAName=${TFA_NAME}/" \
  "${EASY_RSA}/pki/index.txt"

chmod +r "${EASY_RSA}/pki/issued"

CA="$(cat "${EASY_RSA}/pki/ca.crt")"
CERT="$(awk '/-----BEGIN CERTIFICATE-----/{flag=1;next}/-----END CERTIFICATE-----/{flag=0}flag' \
  "${EASY_RSA}/pki/issued/${CERT_NAME}.crt" | tr -d '\0')"
KEY="$(cat "${EASY_RSA}/pki/private/${CERT_NAME}.key")"

# Generate a per-client tls-crypt-v2 key wrapped by the server key
CLIENT_TC2_KEY="${EASY_RSA}/pki/private/${CERT_NAME}_tls_crypt_v2.key"
openvpn \
  --tls-crypt-v2 "${OPENVPN_DIR}/tls-crypt-v2.key" \
  --genkey tls-crypt-v2-client \
  "$CLIENT_TC2_KEY"
TLS_CRYPT_V2="$(cat "$CLIENT_TC2_KEY")"

echo "Generating ${OVPN_FILE_PATH}..."
cat > "${OVPN_FILE_PATH}" <<OVPN_EOF
$(cat "${CLIENT_TEMPLATE}")
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

echo "Done. Client config: ${OVPN_FILE_PATH}"
