#!/usr/bin/env bash
#
# setup.sh
# Configures openvpn-ui on a VM that already has angristan/openvpn-install running.
# Run this script ON THE VM as root, before running deploy.sh from your local machine.
#
# Usage:
#   sudo ./setup.sh init              Interactive guided setup (recommended)
#   sudo ./setup.sh install [FLAGS]   Non-interactive setup
#   sudo ./setup.sh completion        Print bash completion script
#
# Flags for 'install':
#   --admin-username <user>         Admin username (default: admin)
#   --admin-password <pass>         Admin password (required)
#   --maxmind-account-id <id>       MaxMind account ID — enables map view
#   --maxmind-license-key <key>     MaxMind license key
#   --oss-access-key-id <id>        OSS access key ID — enables audit log backup
#   --oss-access-key-secret <sk>    OSS access key secret
#   --oss-bucket <name>             OSS bucket name
#   --oss-endpoint <endpoint>       OSS endpoint (default: oss-me-central-1.aliyuncs.com)
#   --domain <domain>               Domain for Let's Encrypt (HTTPS is always on; self-signed used if omitted)
#   --admin-email <email>           Email for Let's Encrypt (required with --domain)
#   --client-add-form-url <url>     URL shown in place of the Create button (default: Jira form)
#   --client-add-enabled            Re-enable direct client creation (overrides default)
#   --port-forward <lp:ip:dp>       Forward TCP <lp> on this VM to <ip>:<dp> (repeatable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_SRC="${SCRIPT_DIR}/scripts"

OPENVPN_CONF_DIR="/etc/openvpn/server"
SCRIPTS_DST="/opt/scripts"
UI_CONF_DIR="/opt/openvpn-ui/conf"
UI_DB_DIR="/opt/openvpn-ui/db"
UI_COMPOSE="/opt/openvpn-ui/docker-compose.yml"
APP_CONF="${UI_CONF_DIR}/app.conf"
UI_PORT=8080
UI_HTTPS_PORT=8443
DEFAULT_CLIENT_ADD_FORM_URL="https://saudiazmco.atlassian.net/jira/software/form/5853af35-6b8b-4644-84a5-682940f49914"

# Repeatable --port-forward specs collected during flag parsing or interactive init.
# Each element is "<listen-port>:<dest-ip>:<dest-port>".
PORT_FORWARDS=()

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Prompt helpers
# -----------------------------------------------------------------------------
ask_yn() {
  local prompt="$1" default="${2:-n}" answer
  if [[ "$default" == "y" ]]; then
    read -r -p "${prompt} [Y/n] " answer; answer="${answer:-y}"
  else
    read -r -p "${prompt} [y/N] " answer; answer="${answer:-n}"
  fi
  [[ "${answer,,}" == "y" ]]
}

ask_value() {
  local prompt="$1" default="${2:-}" secret="${3:-false}" answer
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "${prompt}: " answer; echo ""
  else
    read -r -p "${prompt}${default:+ (default: ${default})}: " answer
  fi
  echo "${answer:-$default}"
}

usage() {
  cat <<EOF
Usage:
  sudo $0 init                    Interactive guided setup (recommended)
  sudo $0 install [FLAGS]         Non-interactive setup
  sudo $0 completion              Print bash completion script

Flags for 'install':
  --admin-username <user>         Admin username (default: admin)
  --admin-password <pass>         Admin password (required)
  --maxmind-account-id <id>       MaxMind account ID — enables the map view
  --maxmind-license-key <key>     MaxMind license key
  --oss-access-key-id <id>        Alibaba Cloud OSS access key ID
  --oss-access-key-secret <sk>    Alibaba Cloud OSS access key secret
  --oss-bucket <name>             OSS bucket name
  --oss-endpoint <endpoint>       OSS endpoint (default: oss-me-central-1.aliyuncs.com)
  --domain <domain>               Domain name for HTTPS (e.g. vpn.example.com)
  --admin-email <email>           Email for Let's Encrypt (required with --domain)
  --install-docker                Install Docker automatically if not present
  --client-add-form-url <url>     URL shown instead of the Create button (default: Jira form)
  --client-add-enabled            Re-enable direct client creation in the UI
  --port-forward <lp:ip:dp>       Forward TCP <lp> on this VM to <ip>:<dp>. Repeatable.
                                  Example: --port-forward 8443:10.0.1.5:443
EOF
  exit 1
}

# -----------------------------------------------------------------------------
# Bash completion
# -----------------------------------------------------------------------------
print_completion() {
  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"
  cat <<COMPLETION
# Bash completion for ${script_name}
# Enable with: source <(sudo ./${script_name} completion)

_setup_openvpn_ui() {
  local cur prev cmd i
  cur="\${COMP_WORDS[COMP_CWORD]}"
  prev="\${COMP_WORDS[COMP_CWORD-1]}"

  case "\$prev" in
    --admin-username|--admin-password|--maxmind-account-id|--maxmind-license-key| \\
    --oss-access-key-id|--oss-access-key-secret|--oss-bucket|--oss-endpoint| \\
    --domain|--admin-email|--client-add-form-url|--port-forward)
      return 0 ;;
  esac

  cmd=""
  for (( i=1; i<COMP_CWORD; i++ )); do
    case "\${COMP_WORDS[i]}" in
      init|install|completion) cmd="\${COMP_WORDS[i]}"; break ;;
    esac
  done

  if [[ -z "\$cmd" ]]; then
    COMPREPLY=( \$(compgen -W "init install completion" -- "\$cur") )
    return 0
  fi

  case "\$cmd" in
    install)
      COMPREPLY=( \$(compgen -W "
        --admin-username --admin-password
        --maxmind-account-id --maxmind-license-key
        --oss-access-key-id --oss-access-key-secret --oss-bucket --oss-endpoint
        --domain --admin-email
        --client-add-form-url --client-add-enabled
        --port-forward
      " -- "\$cur") ) ;;
  esac
}

complete -F _setup_openvpn_ui ${script_name}
complete -F _setup_openvpn_ui ./${script_name}
COMPLETION
}

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
check_root() {
  [[ "$(id -u)" -eq 0 ]] || err "This script must be run as root: sudo $0 $*"
}

check_openvpn() {
  log "Checking for OpenVPN..."
  [[ -f "${OPENVPN_CONF_DIR}/server.conf" ]] || err \
"OpenVPN server.conf not found at ${OPENVPN_CONF_DIR}/server.conf.
Please run angristan's installer first, then re-run this script:
  curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
  chmod +x openvpn-install.sh
  sudo bash openvpn-install.sh"
  log "OpenVPN found."
}

check_scripts_src() {
  [[ -d "$SCRIPTS_SRC" ]] || err \
"scripts/ directory not found at ${SCRIPTS_SRC}.
Make sure you are running setup.sh from inside the host/ directory of the cloned repository."
}

maybe_install_docker() {
  local force="${1:-false}"
  if command -v docker &>/dev/null; then
    log "Docker already installed."
    return
  fi
  warn "Docker is not installed."
  if [[ "$force" == "true" ]] || { [[ -t 0 ]] && ask_yn "Install Docker now?"; }; then
    log "Installing Docker..."
    apt-get update -qq  > /dev/null 2>&1
    apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg > /dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
    systemctl enable --now docker > /dev/null 2>&1
    log "Docker installed."
  else
    err "Docker is required. Install it and re-run this script.
See: https://docs.docker.com/engine/install/ubuntu/"
  fi
}

# -----------------------------------------------------------------------------
# Setup steps
# -----------------------------------------------------------------------------
setup_management_interface() {
  log "Checking management interface..."
  local conf="${OPENVPN_CONF_DIR}/server.conf"
  if grep -qE "^management[[:space:]]+127\.0\.0\.1[[:space:]]+2080" "$conf"; then
    log "TCP management interface already configured — skipping."
    return
  fi
  # Remove any existing management line (angristan defaults to a Unix socket)
  sed -i '/^management /d' "$conf"
  echo "management 127.0.0.1 2080" >> "$conf"
  log "Added: management 127.0.0.1 2080 to server.conf"
  systemctl restart openvpn-server@server
  log "OpenVPN restarted."
}

setup_pki_symlink() {
  log "Checking PKI symlink..."
  local link="${OPENVPN_CONF_DIR}/pki"
  if [[ -L "$link" ]]; then
    log "PKI symlink already exists — skipping."
  elif [[ -e "$link" ]]; then
    warn "${link} exists but is not a symlink — skipping. Verify manually."
  else
    ln -s "${OPENVPN_CONF_DIR}/easy-rsa/pki" "$link"
    log "Created ${link} -> easy-rsa/pki"
  fi
}

setup_client_template() {
  log "Checking client-template-clean.txt..."
  local src="${OPENVPN_CONF_DIR}/client-template.txt"
  local dst="${OPENVPN_CONF_DIR}/client-template-clean.txt"
  if [[ -f "$dst" ]]; then
    log "client-template-clean.txt already exists — skipping."
    return
  fi
  [[ -f "$src" ]] || { warn "client-template.txt not found at ${src} — skipping."; return; }
  sed '/^<tls-crypt-v2>/,/^<\/tls-crypt-v2>/d; /^tls-crypt-v2[[:space:]]/d' \
    "$src" > "$dst"
  log "Created client-template-clean.txt"
}

setup_directories() {
  log "Creating directories..."
  mkdir -p \
    "${UI_CONF_DIR}" \
    "${UI_DB_DIR}" \
    "${SCRIPTS_DST}" \
    "${OPENVPN_CONF_DIR}/clients" \
    "${OPENVPN_CONF_DIR}/staticclients"
  chmod 755 "$SCRIPTS_DST"
  log "Directories ready."
}

install_scripts() {
  log "Installing helper scripts to ${SCRIPTS_DST}/..."
  cp "${SCRIPTS_SRC}"/*.sh "$SCRIPTS_DST/"
  chmod +x "${SCRIPTS_DST}"/*.sh
  log "Scripts installed."
}

install_ossutil() {
  if command -v ossutil &>/dev/null; then
    log "ossutil already installed."
    return
  fi
  log "Installing ossutil..."
  curl -fsSL https://gosspublic.alicdn.com/ossutil/install.sh \
    -o /tmp/ossutil-install.sh
  bash /tmp/ossutil-install.sh < /dev/null > /dev/null 2>&1
  rm -f /tmp/ossutil-install.sh
  log "ossutil installed."
}

write_ossconfig() {
  cat > /root/.ossutilconfig <<OSSCONF
[Credentials]
language=EN
accessKeyID=${1}
accessKeySecret=${2}
endpoint=${3}
OSSCONF
  chmod 600 /root/.ossutilconfig
  log "OSS credentials written to /root/.ossutilconfig"
}

setup_geoip() {
  log "Setting up MaxMind GeoLite2-City..."
  if ! command -v geoipupdate &>/dev/null; then
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq --no-install-recommends geoipupdate > /dev/null 2>&1
  fi
  mkdir -p /usr/share/GeoIP
  cat > /etc/GeoIP.conf <<GEOCONF
AccountID ${1}
LicenseKey ${2}
EditionIDs GeoLite2-City
DatabaseDirectory /usr/share/GeoIP
GEOCONF
  geoipupdate \
    && log "GeoLite2-City database downloaded." \
    || warn "geoipupdate failed — map markers will be unavailable until the database is present."
}

setup_tls() {
  local domain="$1" email="$2"
  log "Setting up Let's Encrypt for ${domain}..."
  if ! command -v certbot &>/dev/null; then
    apt-get update -qq > /dev/null 2>&1
    apt-get install -y -qq --no-install-recommends certbot > /dev/null 2>&1
  fi
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    log "Certificate for ${domain} already exists — skipping."
    return
  fi
  warn "Let's Encrypt requires port 80 to be open on this machine."
  warn "If your firewall or cloud security group blocks port 80, certificate"
  warn "issuance will fail. Open it now, then close it again once setup completes."
  local email_flag="--register-unsafely-without-email"
  [[ -n "$email" ]] && email_flag="--email ${email}"
  # shellcheck disable=SC2086
  certbot certonly --standalone --non-interactive --agree-tos \
    ${email_flag} -d "${domain}" \
    || warn "certbot failed — HTTPS will not work until the certificate is obtained."
  (crontab -l 2>/dev/null | grep -v "certbot renew" || true; \
    echo "0 3,15 * * * certbot renew --quiet && docker compose -f ${UI_COMPOSE} restart") \
    | crontab -
  log "TLS configured. Renewal cron added."
}

setup_selfsigned_tls() {
  local cert_file="${UI_CONF_DIR}/selfsigned.crt"
  local key_file="${UI_CONF_DIR}/selfsigned.key"
  if [[ -f "$cert_file" && -f "$key_file" ]]; then
    log "Self-signed TLS cert already exists — skipping."
    return
  fi
  log "Generating self-signed TLS certificate..."
  local server_ip
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$key_file" -out "$cert_file" \
    -days 3650 -subj "/CN=${server_ip}" \
    -addext "subjectAltName=IP:${server_ip}" 2>/dev/null
  log "Self-signed TLS cert generated."
}

write_app_conf() {
  local geoip_path="${1:-}" oss_bucket="${2:-}" oss_endpoint="${3:-}"
  local tls_cert="${4:-}" tls_key="${5:-}"
  local client_add_disabled="${6:-true}" client_add_form_url="${7:-$DEFAULT_CLIENT_ADD_FORM_URL}"

  local server_ip
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

  cat > "$APP_CONF" <<APPCONF
AppName                    = openvpn-ui
HttpPort                   = ${UI_PORT}
RunMode                    = prod
EnableGzip                 = true
EnableAdmin                = true
SessionOn                  = true
CopyRequestBody            = true
DbPath                     = "./db/data.db"
AuthType                   = "password"
EasyRsaPath                = "/usr/share/easy-rsa"
OpenVpnPath                = "/etc/openvpn"
OpenVpnManagementAddress   = "127.0.0.1:2080"
OpenVpnManagementNetwork   = "tcp"
GeoipDbPath                = ${geoip_path}
OVClientsDir               = "/root"
OSSLogBucket               = ${oss_bucket}
OSSEndpoint                = ${oss_endpoint}
ServerAddress              = ${server_ip}
ClientAddDisabled          = ${client_add_disabled}
ClientAddFormURL           = ${client_add_form_url}
APPCONF

  if [[ -n "$tls_cert" && -n "$tls_key" ]]; then
    cat >> "$APP_CONF" <<APPCONF_TLS
EnableHTTPS                = true
HTTPSPort                  = ${UI_HTTPS_PORT}
HTTPSCertFile              = ${tls_cert}
HTTPSKeyFile               = ${tls_key}
APPCONF_TLS
  fi
  log "app.conf written."
}

write_compose() {
  local admin_user="$1" admin_pass="$2"
  local geoip_enabled="${3:-false}" oss_enabled="${4:-false}" domain="${5:-}"

  {
    cat <<COMPOSE
services:
  openvpn-ui:
    image: openvpn-ui-local:latest
    container_name: openvpn-ui
    environment:
      - OPENVPN_ADMIN_USERNAME=${admin_user}
      - OPENVPN_ADMIN_PASSWORD=${admin_pass}
    network_mode: host
    cap_add:
      - NET_ADMIN
    volumes:
      - ${OPENVPN_CONF_DIR}:/etc/openvpn
      - ${OPENVPN_CONF_DIR}/easy-rsa:/usr/share/easy-rsa
      - /opt/openvpn-ui/db:/opt/openvpn-ui/db
      - /opt/openvpn-ui/conf:/opt/openvpn-ui/conf
      - /opt/scripts:/opt/scripts
      - /root:/root
      - /etc/iptables:/etc/iptables
      - /etc/sysctl.d:/etc/sysctl.d
COMPOSE
    [[ "$oss_enabled"   == "true" ]] && echo "      - /root/.ossutilconfig:/root/.ossutilconfig:ro"
    [[ "$geoip_enabled" == "true" ]] && echo "      - /usr/share/GeoIP:/usr/share/GeoIP:ro"
    if [[ -n "$domain" ]]; then
      echo "      - /etc/letsencrypt/live/${domain}:/etc/letsencrypt/live/${domain}:ro"
      echo "      - /etc/letsencrypt/archive/${domain}:/etc/letsencrypt/archive/${domain}:ro"
    fi
    echo "    restart: always"
  } > "$UI_COMPOSE"
  log "docker-compose.yml written."
}

setup_iptables_persistence() {
  # Always install iptables-persistent on the host so iptables rules survive
  # reboots regardless of whether they are added via setup.sh --port-forward,
  # /opt/scripts/port-forward.sh, or the openvpn-ui Port-forwarding page.
  # The UI runs from an Alpine container that has the iptables binary but not
  # apt-get, so the host is the only place that can install netfilter-persistent.
  if dpkg -s iptables-persistent >/dev/null 2>&1; then return; fi
  log "Installing iptables-persistent on host..."
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" \
    | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" \
    | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent \
    >/dev/null 2>&1
  mkdir -p /etc/iptables
  log "iptables-persistent installed."
}

apply_port_forwards() {
  [[ ${#PORT_FORWARDS[@]} -eq 0 ]] && return 0
  local spec lp di dp
  for spec in "${PORT_FORWARDS[@]}"; do
    [[ "$spec" =~ ^[0-9]+:[0-9.]+:[0-9]+$ ]] \
      || err "Invalid --port-forward spec '${spec}'. Expected <listen-port>:<dest-ip>:<dest-port>."
    IFS=':' read -r lp di dp <<< "$spec"
    log "Configuring port forward: tcp/${lp} -> ${di}:${dp}"
    "${SCRIPTS_DST}/port-forward.sh" add "$lp" "$di" "$dp"
  done
}

setup_cron() {
  log "Installing cron jobs..."
  cat > /etc/cron.d/openvpn-logs <<'LOGCRON'
# Collect new OpenVPN journal lines into the master log every minute
* * * * * root /opt/scripts/ovpn-log-collect.sh >> /var/log/ovpn-collect.log 2>&1
# Rotate to OSS if master log >= 10 MB (checked every 5 minutes)
*/5 * * * * root /opt/scripts/ovpn-log-rotate.sh >> /var/log/ovpn-rotate.log 2>&1
# End-of-day rotation at 23:59 UTC
59 23 * * * root /opt/scripts/ovpn-log-rotate.sh --eod >> /var/log/ovpn-rotate.log 2>&1
# Restart OpenVPN at 23:59 if a revocation was made today
59 23 * * * root [ -f /run/openvpn-restart-pending ] && rm -f /run/openvpn-restart-pending && systemctl restart openvpn-server@server
LOGCRON
  chmod 644 /etc/cron.d/openvpn-logs

  # Logs page snapshot — journalctl is not available inside the Alpine container
  (crontab -l 2>/dev/null | grep -v "ovpn-logs.txt" || true; \
    echo "* * * * * journalctl -n 300 -xeu openvpn-server@server.service --no-pager > /opt/scripts/ovpn-logs.txt 2>&1") \
    | crontab -
  log "Cron jobs installed."
}

print_next_steps() {
  local server_ip
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

  echo ""
  echo "============================================================"
  echo "  VM setup complete."
  echo "============================================================"
  echo ""
  echo "  The Docker image must be built on your local machine"
  echo "  (the VM does not have enough RAM to build it)."
  echo ""
  echo "  On your local machine, run:"
  echo ""
  echo "    ./host/deploy.sh --vm-ip ${server_ip}"
  echo ""
  echo "  Or with a custom SSH key:"
  echo ""
  echo "    ./host/deploy.sh --vm-ip ${server_ip} --vm-ssh-key ~/.ssh/your_key"
  echo ""
  echo "============================================================"
}

# -----------------------------------------------------------------------------
# Core installer (shared by init and install)
# -----------------------------------------------------------------------------
run_install() {
  local admin_user="$1"     admin_pass="$2"
  local maxmind_id="$3"     maxmind_key="$4"
  local oss_key_id="$5"     oss_key_secret="$6"
  local oss_bucket="$7"     oss_endpoint="$8"
  local domain="$9"         admin_email="${10}"
  local install_docker="${11:-false}"
  local client_add_disabled="${12:-true}"
  local client_add_form_url="${13:-$DEFAULT_CLIENT_ADD_FORM_URL}"

  local geoip_path="" geoip_enabled="false" oss_enabled="false"

  check_openvpn
  check_scripts_src
  maybe_install_docker "$install_docker"

  if ! command -v crontab &>/dev/null; then
    log "Installing cron..."
    apt-get install -y -qq cron > /dev/null 2>&1
    systemctl enable --now cron > /dev/null 2>&1
    log "cron installed."
  fi

  setup_directories
  setup_management_interface
  setup_pki_symlink
  setup_client_template
  install_scripts

  if [[ -n "$oss_key_id" && -n "$oss_key_secret" && -n "$oss_bucket" ]]; then
    install_ossutil
    write_ossconfig "$oss_key_id" "$oss_key_secret" "$oss_endpoint"
    oss_enabled="true"
  else
    log "OSS not configured — audit log backup disabled."
  fi

  if [[ -n "$maxmind_id" && -n "$maxmind_key" ]]; then
    setup_geoip "$maxmind_id" "$maxmind_key"
    geoip_path="/usr/share/GeoIP/GeoLite2-City.mmdb"
    geoip_enabled="true"
  else
    log "MaxMind not configured — map markers disabled."
  fi

  local tls_cert="" tls_key=""
  if [[ -n "$domain" ]]; then
    setup_tls "$domain" "$admin_email"
    tls_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    tls_key="/etc/letsencrypt/live/${domain}/privkey.pem"
  else
    setup_selfsigned_tls
    tls_cert="${UI_CONF_DIR}/selfsigned.crt"
    tls_key="${UI_CONF_DIR}/selfsigned.key"
  fi

  write_app_conf "$geoip_path" "$oss_bucket" "$oss_endpoint" "$tls_cert" "$tls_key" "$client_add_disabled" "$client_add_form_url"
  write_compose "$admin_user" "$admin_pass" "$geoip_enabled" "$oss_enabled" "$domain"
  setup_cron
  setup_iptables_persistence
  apply_port_forwards
  print_next_steps
}

# -----------------------------------------------------------------------------
# Interactive init
# -----------------------------------------------------------------------------
run_init() {
  echo ""
  echo "============================================================"
  echo "  openvpn-ui — interactive setup"
  echo "============================================================"
  echo "  Configures openvpn-ui on this machine."
  echo "  Press Ctrl+C at any time to cancel."
  echo "============================================================"
  echo ""

  check_openvpn
  check_scripts_src
  maybe_install_docker

  # Admin credentials
  local admin_user admin_pass admin_confirm
  admin_user=$(ask_value "Admin username" "admin")
  while true; do
    admin_pass=$(ask_value "Admin password" "" "true")
    [[ -n "$admin_pass" ]] || { warn "Password cannot be empty."; continue; }
    admin_confirm=$(ask_value "Confirm password" "" "true")
    [[ "$admin_pass" == "$admin_confirm" ]] && break
    warn "Passwords do not match — try again."
  done

  # Map view (GeoIP) — optional
  local maxmind_id="" maxmind_key=""
  echo ""
  echo "--- Map View (optional) ---"
  echo "Shows connected clients plotted on a world map using MaxMind GeoLite2."
  echo "Requires a free MaxMind account: https://www.maxmind.com"
  if ask_yn "Enable the map view?"; then
    maxmind_id=$(ask_value "MaxMind Account ID")
    maxmind_key=$(ask_value "MaxMind License Key" "" "true")
  fi

  # Audit log backup (OSS) — optional
  local oss_key_id="" oss_key_secret="" oss_bucket="" oss_endpoint="oss-me-central-1.aliyuncs.com"
  echo ""
  echo "--- Audit Log Backup (optional) ---"
  echo "Compresses and uploads OpenVPN session logs to Alibaba Cloud OSS."
  echo "Enables the audit log browser at /logs/browse."
  if ask_yn "Enable audit log backup?"; then
    oss_key_id=$(ask_value "OSS Access Key ID")
    oss_key_secret=$(ask_value "OSS Access Key Secret" "" "true")
    oss_bucket=$(ask_value "OSS Bucket Name")
    oss_endpoint=$(ask_value "OSS Endpoint" "oss-me-central-1.aliyuncs.com")
  fi

  # Client creation restriction — optional
  local client_add_disabled="true" client_add_form_url="$DEFAULT_CLIENT_ADD_FORM_URL"
  echo ""
  echo "--- Client Creation ---"
  echo "By default, direct client creation is disabled and redirected to an external form."
  if ask_yn "Enable direct client creation in the UI?"; then
    client_add_disabled="false"
    client_add_form_url=""
  else
    client_add_form_url=$(ask_value "Form URL" "$DEFAULT_CLIENT_ADD_FORM_URL")
  fi

  # Port forwarding — optional, repeatable
  echo ""
  echo "--- Port Forwarding (optional) ---"
  echo "Forward TCP traffic on a port of this VM to an intranet <ip>:<port>."
  echo "Useful when VPN clients need access to a service that is otherwise unreachable."
  if ask_yn "Add port-forward rules?"; then
    while true; do
      local pf_lp pf_di pf_dp
      pf_lp=$(ask_value "Listen port (on this VM)")
      [[ -z "$pf_lp" ]] && { warn "Empty port — stopping."; break; }
      pf_di=$(ask_value "Destination IP")
      pf_dp=$(ask_value "Destination port")
      PORT_FORWARDS+=("${pf_lp}:${pf_di}:${pf_dp}")
      ask_yn "Add another rule?" || break
    done
  fi

  # HTTPS / TLS — always on; optionally use Let's Encrypt
  local domain="" admin_email=""
  echo ""
  echo "--- HTTPS / TLS ---"
  echo "The UI always uses HTTPS. By default, a self-signed certificate is generated."
  echo "Optionally, provide a domain name to get a free Let's Encrypt certificate instead."
  echo "(Requires the domain to point at this server and port 80 to be open temporarily.)"
  if ask_yn "Use Let's Encrypt with a domain name?"; then
    domain=$(ask_value "Domain name (e.g. vpn.example.com)")
    admin_email=$(ask_value "Email for Let's Encrypt")
  fi

  echo ""
  log "Starting installation..."
  echo ""

  run_install \
    "$admin_user"    "$admin_pass" \
    "$maxmind_id"    "$maxmind_key" \
    "$oss_key_id"    "$oss_key_secret" "$oss_bucket" "$oss_endpoint" \
    "$domain"        "$admin_email" \
    "false" \
    "$client_add_disabled" "$client_add_form_url"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
[[ $# -eq 0 ]] && usage

check_root "$@"

COMMAND="$1"; shift

case "$COMMAND" in
  completion) print_completion; exit 0 ;;
  init)       run_init;         exit 0 ;;
  install)    : ;;  # fall through to flag parsing below
  -h|--help)  usage ;;
  *)          err "Unknown command: '${COMMAND}'. Run '$0' for usage." ;;
esac

# Non-interactive: parse flags
ADMIN_USER="admin"; ADMIN_PASS=""
MAXMIND_ID="";      MAXMIND_KEY=""
OSS_KEY_ID="";      OSS_KEY_SECRET=""; OSS_BUCKET=""; OSS_ENDPOINT="oss-me-central-1.aliyuncs.com"
DOMAIN="";          ADMIN_EMAIL=""
INSTALL_DOCKER="false"
CLIENT_ADD_DISABLED="true"; CLIENT_ADD_FORM_URL="$DEFAULT_CLIENT_ADD_FORM_URL"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-username)        ADMIN_USER="$2";       shift 2 ;;
    --admin-password)        ADMIN_PASS="$2";       shift 2 ;;
    --maxmind-account-id)    MAXMIND_ID="$2";       shift 2 ;;
    --maxmind-license-key)   MAXMIND_KEY="$2";      shift 2 ;;
    --oss-access-key-id)     OSS_KEY_ID="$2";       shift 2 ;;
    --oss-access-key-secret) OSS_KEY_SECRET="$2";   shift 2 ;;
    --oss-bucket)            OSS_BUCKET="$2";       shift 2 ;;
    --oss-endpoint)          OSS_ENDPOINT="$2";     shift 2 ;;
    --domain)                DOMAIN="$2";           shift 2 ;;
    --admin-email)           ADMIN_EMAIL="$2";      shift 2 ;;
    --install-docker)        INSTALL_DOCKER="true";                shift   ;;
    --client-add-form-url)   CLIENT_ADD_FORM_URL="$2";            shift 2 ;;
    --client-add-enabled)    CLIENT_ADD_DISABLED="false"; CLIENT_ADD_FORM_URL=""; shift ;;
    --port-forward)
      [[ -n "${2:-}" ]] || err "--port-forward requires <listen-port>:<dest-ip>:<dest-port>"
      PORT_FORWARDS+=("$2"); shift 2 ;;
    *) err "Unknown flag: $1. Run '$0 install' with no flags to see usage." ;;
  esac
done

[[ -n "$ADMIN_PASS" ]] \
  || err "--admin-password is required for non-interactive setup.
For a guided setup, use: sudo $0 init"

run_install \
  "$ADMIN_USER"    "$ADMIN_PASS" \
  "$MAXMIND_ID"    "$MAXMIND_KEY" \
  "$OSS_KEY_ID"    "$OSS_KEY_SECRET" "$OSS_BUCKET" "$OSS_ENDPOINT" \
  "$DOMAIN"        "$ADMIN_EMAIL" \
  "$INSTALL_DOCKER" \
  "$CLIENT_ADD_DISABLED" "$CLIENT_ADD_FORM_URL"
