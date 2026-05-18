#!/bin/bash
# Bulk removal operations for openvpn-ui (danger zone).
# Called by openvpn-ui for PKI and data reset operations.
#
# Usage: remove.sh <action>
#   remove_pki             Delete all PKI files (certificates, keys, CRL)
#   remove_ovpn            Delete all client .ovpn config files
#   remove_static_clients  Delete all static client IP assignments
#   remove_ovpn_db         Delete the openvpn-ui SQLite database
#   remove_all             remove_pki + remove_ovpn + remove_static_clients

set -e

ACTION="$1"
EASY_RSA="/usr/share/easy-rsa"
OPENVPN_DIR="/etc/openvpn"

case "$ACTION" in
  remove_pki)
    rm -rf "${EASY_RSA}/pki/"*
    echo "PKI removed." ;;
  remove_ovpn)
    rm -rf "${OPENVPN_DIR}/clients/"*.ovpn
    echo "*.ovpn files removed." ;;
  remove_static_clients)
    rm -rf "${OPENVPN_DIR}/staticclients/"*
    echo "Static clients removed." ;;
  remove_ovpn_db)
    rm -f /opt/openvpn-ui/db/data.db
    echo "openvpn-ui database removed." ;;
  remove_all)
    rm -rf "${EASY_RSA}/pki/"*
    rm -rf "${OPENVPN_DIR}/clients/"*.ovpn
    rm -rf "${OPENVPN_DIR}/staticclients/"*
    echo "All removed." ;;
  *)
    echo "Usage: remove.sh <remove_pki|remove_ovpn|remove_static_clients|remove_ovpn_db|remove_all>" >&2
    exit 75 ;;
esac
