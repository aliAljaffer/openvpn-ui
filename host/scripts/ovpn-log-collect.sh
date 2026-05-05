#!/bin/bash
# Appends new OpenVPN journal lines to the master log using a saved cursor.
# Safe to run multiple times — no lines are duplicated between runs.
# Run every minute via cron.

MASTER_LOG="/opt/scripts/ovpn-master.log"
CURSOR_FILE="/opt/scripts/ovpn-journal.cursor"
UNIT="openvpn-server@server"

if [[ -f "$CURSOR_FILE" ]]; then
  journalctl -u "$UNIT" --after-cursor="$(cat "$CURSOR_FILE")" \
    --no-pager -o short-iso >> "$MASTER_LOG"
else
  journalctl -u "$UNIT" -n 200 --no-pager -o short-iso >> "$MASTER_LOG"
fi

journalctl -u "$UNIT" --show-cursor -n 0 --no-pager 2>/dev/null \
  | grep "^-- cursor:" | awk '{print $NF}' > "$CURSOR_FILE"
