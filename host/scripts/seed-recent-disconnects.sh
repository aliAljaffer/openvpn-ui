#!/bin/bash
# One-shot seed for the Map View "recently disconnected" markers.
#
# Writes example disconnected sessions to the JSON store, each stamped within the
# last hour so they appear immediately as faded markers and then expire on their
# own per the 1-hour window (see recentWindow in mapview.go). Run once on the
# server to verify the feature end to end:
#
#   sudo /opt/scripts/seed-recent-disconnects.sh
#
# Coordinates are baked in (city centers) so every marker shows regardless of
# whether the server's GeoIP database resolves the IP. Still-connected users are
# intentionally omitted — they render as solid markers from the live management
# interface, not faded ones.

set -euo pipefail

OUT="${1:-/opt/scripts/recent-disconnects.json}"
now="$(date +%s)"

# epoch N seconds ago — all stamped within the last few minutes so the full set
# is visible together right after seeding (they then expire over the next hour).
ago() { echo $(( now - $1 )); }

tmp="${OUT}.tmp.$$"
cat > "$tmp" <<JSON
[
  {"cn":"sekaya-azm-dev-zain-raza","ip":"110.93.211.154","disconnect_epoch":$(ago 60),"duration":"44m59s","country":"Pakistan","city":"","lat":30.3753,"lng":69.3451},
  {"cn":"azmsa-abdullah-tailakh","ip":"188.123.180.10","disconnect_epoch":$(ago 90),"duration":"39m57s","country":"Jordan","city":"Amman","lat":31.9539,"lng":35.9106},
  {"cn":"azmsa-huthayfa-battah","ip":"46.185.190.42","disconnect_epoch":$(ago 120),"duration":"3h25m19s","country":"Jordan","city":"Amman","lat":31.9539,"lng":35.9106},
  {"cn":"sekaya-azm-squad-alaa-abdelmotlep","ip":"197.35.192.20","disconnect_epoch":$(ago 150),"duration":"11m28s","country":"Egypt","city":"Cairo","lat":30.0444,"lng":31.2357},
  {"cn":"sekaya-sitech-mohammad-dabbah","ip":"46.185.191.221","disconnect_epoch":$(ago 180),"duration":"11s","country":"Jordan","city":"Amman","lat":31.9539,"lng":35.9106},
  {"cn":"sekaya-sitech-beshoy","ip":"41.233.178.22","disconnect_epoch":$(ago 210),"duration":"4m19s","country":"Egypt","city":"Cairo","lat":30.0444,"lng":31.2357},
  {"cn":"sekaya-sitech-beshoy","ip":"41.42.136.56","disconnect_epoch":$(ago 240),"duration":"1m36s","country":"Egypt","city":"Giza","lat":30.0131,"lng":31.2089},
  {"cn":"sekaya-sitech-beshoy","ip":"45.104.107.118","disconnect_epoch":$(ago 270),"duration":"37s","country":"Egypt","city":"Cairo","lat":30.0444,"lng":31.2357}
]
JSON

mv "$tmp" "$OUT"
chmod 644 "$OUT"
echo "Seeded $OUT with 8 example recent disconnects (visible for up to 1 hour)."
