#!/bin/bash
# Restarts the OpenVPN service or the openvpn-ui Docker container.
# Called by openvpn-ui for server and container restart operations.
#
# Usage: restart.sh [openvpn-server|openvpn-ui]
#   openvpn-server   Restart the OpenVPN systemd service (default)
#   openvpn-ui       Restart the openvpn-ui Docker container

set -e

ACTION="${1:-openvpn-server}"

case "$ACTION" in
  openvpn-server)
    systemctl restart openvpn-server@server
    echo "openvpn-server@server restarted." ;;
  openvpn-ui)
    docker restart openvpn-ui
    echo "openvpn-ui container restarted." ;;
  *)
    echo "Usage: restart.sh [openvpn-server|openvpn-ui]" >&2
    exit 1 ;;
esac
