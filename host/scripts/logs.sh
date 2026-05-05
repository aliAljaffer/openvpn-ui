#!/bin/bash
# Outputs the most recent OpenVPN journal snapshot for the openvpn-ui Logs page.
# The snapshot is written every minute by a host cron job (journalctl is not
# available inside the Alpine container).
cat /opt/scripts/ovpn-logs.txt 2>/dev/null || echo "No logs yet."
