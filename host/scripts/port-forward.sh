#!/bin/bash
# port-forward.sh — manage TCP port-forwarding NAT rules on the VPN VM.
#
# Forwards traffic arriving on <LISTEN_PORT> on this host to <DEST_IP>:<DEST_PORT>.
# Useful when VPN clients need to reach an intranet service that is only
# routable from this VM. Rules persist across reboots via iptables-persistent.
#
# Usage:
#   port-forward.sh add    <listen-port> <dest-ip> <dest-port>
#   port-forward.sh list   [--format json]
#   port-forward.sh remove <listen-port>
#
# Rules are identified by their listen port — a single listen port maps to
# exactly one destination at a time. To repoint an existing port, remove first.

set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-openvpn-forward.conf"

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || err "port-forward.sh must be run as root."

# Alpine detection — the openvpn-ui container is Alpine and mutates host iptables
# via NET_ADMIN + network_mode:host. Persistence (writing /etc/iptables/rules.v4)
# happens inside the container; the host's iptables-persistent service restores
# rules on boot. setup.sh is responsible for installing iptables-persistent on
# the host; the container only needs the iptables/iptables-save binaries.
IS_ALPINE=0
[[ -f /etc/alpine-release ]] && IS_ALPINE=1

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

ensure_iptables_persistent() {
  if (( IS_ALPINE )); then
    # Inside the openvpn-ui Alpine container — assume the host already has
    # iptables-persistent installed by setup.sh. Just make sure the rules
    # directory exists so iptables-save can write into it.
    mkdir -p /etc/iptables
    return
  fi
  if dpkg -s iptables-persistent >/dev/null 2>&1; then return; fi
  log "Installing iptables-persistent..."
  # Pre-seed debconf so the install does not prompt to save current rules.
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" \
    | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" \
    | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent \
    >/dev/null 2>&1
}

persist_rules() {
  if (( IS_ALPINE )); then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
  else
    persist_rules
  fi
}

ensure_ip_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if [[ ! -f "$SYSCTL_FILE" ]]; then
    echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE"
    log "IPv4 forwarding persisted in ${SYSCTL_FILE}"
  fi
}

# Returns existing destination as "ip port" if a PREROUTING rule for the given
# listen port exists, or empty string otherwise.
existing_dest_for_port() {
  local listen_port="$1"
  iptables -t nat -S PREROUTING 2>/dev/null \
    | sed -nE "s/^-A PREROUTING -p tcp -m tcp --dport ${listen_port} -j DNAT --to-destination ([0-9.]+):([0-9]+).*$/\1 \2/p" \
    | head -1
}

cmd_add() {
  local listen_port="$1" dest_ip="$2" dest_port="$3"

  valid_port "$listen_port" || err "listen-port must be 1-65535: '${listen_port}'"
  valid_ipv4 "$dest_ip"     || err "dest-ip must be a dotted IPv4 address: '${dest_ip}'"
  valid_port "$dest_port"   || err "dest-port must be 1-65535: '${dest_port}'"

  ensure_iptables_persistent
  ensure_ip_forward

  local existing
  existing=$(existing_dest_for_port "$listen_port")
  if [[ -n "$existing" ]]; then
    local cur_ip cur_port
    read -r cur_ip cur_port <<< "$existing"
    if [[ "$cur_ip" == "$dest_ip" && "$cur_port" == "$dest_port" ]]; then
      log "Rule already present: tcp/${listen_port} -> ${dest_ip}:${dest_port} — skipping."
      return 0
    fi
    err "tcp/${listen_port} already forwards to ${cur_ip}:${cur_port}. Remove it first: $0 remove ${listen_port}"
  fi

  log "Adding NAT rule: tcp/${listen_port} -> ${dest_ip}:${dest_port}"
  iptables -t nat -A PREROUTING \
    -p tcp --dport "${listen_port}" \
    -j DNAT --to-destination "${dest_ip}:${dest_port}"

  if ! iptables -t nat -C POSTROUTING \
        -p tcp -d "${dest_ip}" --dport "${dest_port}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING \
      -p tcp -d "${dest_ip}" --dport "${dest_port}" -j MASQUERADE
  fi

  persist_rules
  log "Rule added and persisted."
}

cmd_list() {
  local format="text"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      --format=json|--json) format="json" ;;
      --format) shift; [[ "${1:-}" == "json" ]] && format="json" || err "Unknown format: '${1:-}'" ;;
      --format=text) format="text" ;;
      *) err "Unknown list flag: '$1'" ;;
    esac
  fi

  if [[ "$format" == "json" ]]; then
    cmd_list_json
    return
  fi

  echo "IPv4 forwarding: $(sysctl -n net.ipv4.ip_forward)"
  echo ""
  echo "Configured port-forward rules (PREROUTING DNAT):"
  local lines
  lines=$(iptables -t nat -S PREROUTING 2>/dev/null \
    | sed -nE 's/^-A PREROUTING -p tcp -m tcp --dport ([0-9]+) -j DNAT --to-destination ([0-9.]+):([0-9]+).*$/  tcp\/\1 -> \2:\3/p')
  if [[ -z "$lines" ]]; then
    echo "  (none)"
  else
    echo "$lines"
  fi
  echo ""
  echo "Raw NAT table:"
  iptables -t nat -L -n --line-numbers
}

# Emit configured rules as compact JSON for programmatic consumers (e.g., the UI).
# Shape: {"ip_forward":1,"rules":[{"listen_port":8443,"dest_ip":"10.0.0.5","dest_port":443}]}
cmd_list_json() {
  local fwd
  fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)

  local rules_csv
  rules_csv=$(iptables -t nat -S PREROUTING 2>/dev/null \
    | sed -nE 's/^-A PREROUTING -p tcp -m tcp --dport ([0-9]+) -j DNAT --to-destination ([0-9.]+):([0-9]+).*$/\1,\2,\3/p')

  printf '{"ip_forward":%s,"rules":[' "$fwd"
  local first=1 lp ip dp
  while IFS=',' read -r lp ip dp; do
    [[ -z "$lp" ]] && continue
    [[ $first -eq 0 ]] && printf ','
    printf '{"listen_port":%s,"dest_ip":"%s","dest_port":%s}' "$lp" "$ip" "$dp"
    first=0
  done <<< "$rules_csv"
  printf ']}\n'
}

cmd_remove() {
  local listen_port="$1"
  valid_port "$listen_port" || err "listen-port must be 1-65535: '${listen_port}'"

  local existing
  existing=$(existing_dest_for_port "$listen_port")
  if [[ -z "$existing" ]]; then
    log "No rule found for listen-port ${listen_port} — nothing to remove."
    return 0
  fi

  local dest_ip dest_port
  read -r dest_ip dest_port <<< "$existing"

  log "Removing NAT rule: tcp/${listen_port} -> ${dest_ip}:${dest_port}"
  iptables -t nat -D PREROUTING \
    -p tcp --dport "${listen_port}" \
    -j DNAT --to-destination "${dest_ip}:${dest_port}"

  # Drop the matching POSTROUTING MASQUERADE only if no other rule still
  # forwards to the same dest, so unrelated rules keep working.
  local still_used
  still_used=$(iptables -t nat -S PREROUTING 2>/dev/null \
    | grep -cE -- "-j DNAT --to-destination ${dest_ip}:${dest_port}\$" || true)
  if [[ "${still_used:-0}" -eq 0 ]]; then
    iptables -t nat -D POSTROUTING \
      -p tcp -d "${dest_ip}" --dport "${dest_port}" -j MASQUERADE 2>/dev/null || true
  fi

  persist_rules
  log "Rule removed and persisted."
}

usage() {
  cat <<EOF
Usage:
  $0 add    <listen-port> <dest-ip> <dest-port>
  $0 list   [--format json]
  $0 remove <listen-port>
EOF
  exit 1
}

[[ $# -gt 0 ]] || usage
cmd="$1"; shift

case "$cmd" in
  add)
    [[ $# -eq 3 ]] || usage
    cmd_add "$@"
    ;;
  list)
    cmd_list "$@"
    ;;
  remove)
    [[ $# -eq 1 ]] || usage
    cmd_remove "$@"
    ;;
  -h|--help) usage ;;
  *) err "Unknown command: '${cmd}'. Use add, list, or remove." ;;
esac
