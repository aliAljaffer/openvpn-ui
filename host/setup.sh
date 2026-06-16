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
#   --storage-provider <name>       Log archive backend: local|oss|s3|gcs (default: local)
#   --local-log-dir <path>          Archive directory for --storage-provider=local
#                                   (default: /var/log/openvpn-ui/archives)
#   --oss-access-key-id <id>        OSS access key ID (required when --storage-provider=oss)
#   --oss-access-key-secret <sk>    OSS access key secret
#   --oss-bucket <name>             OSS bucket name
#   --oss-endpoint <endpoint>       OSS endpoint (default: oss-me-central-1.aliyuncs.com)
#   --s3-access-key-id <id>         AWS access key ID (required when --storage-provider=s3)
#   --s3-secret-access-key <sk>     AWS secret access key
#   --s3-bucket <name>              S3 bucket name
#   --s3-region <region>            AWS region (e.g. us-east-1)
#   --gcs-bucket <name>             GCS bucket name (required when --storage-provider=gcs)
#   --gcs-project-id <id>           GCP project ID
#   --gcs-key-file <path>           Path on this VM to a GCP service account JSON key file
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
DEFAULT_LOCAL_LOG_DIR="/var/log/openvpn-ui/archives"
DEFAULT_GCS_KEY_DEST="/etc/openvpn-ui/gcs-sa-key.json"

# Repeatable --port-forward specs collected during flag parsing or interactive init.
# Each element is "<listen-port>:<dest-ip>:<dest-port>".
PORT_FORWARDS=()

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  {
  local code=1
  [[ "${1:-}" =~ ^[0-9]+$ ]] && { code="$1"; shift; }
  echo -e "${RED}[ERROR]${RESET} $*" >&2
  exit "$code"
}

# Wait up to 60s for the dpkg lock so unattended-upgrades on a fresh VM
# doesn't cause apt-get to fail instantly. stderr is left visible on purpose.
apt_get() {
  apt-get -o DPkg::Lock::Timeout=60 -qq "$@"
}

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
  --storage-provider <name>       Log archive backend: local|oss|s3|gcs (default: local)
  --local-log-dir <path>          Archive directory for the local backend
                                  (default: ${DEFAULT_LOCAL_LOG_DIR})
  --oss-access-key-id <id>        Alibaba Cloud OSS access key ID (storage-provider=oss)
  --oss-access-key-secret <sk>    Alibaba Cloud OSS access key secret
  --oss-bucket <name>             OSS bucket name
  --oss-endpoint <endpoint>       OSS endpoint (default: oss-me-central-1.aliyuncs.com)
  --s3-access-key-id <id>         AWS access key ID (storage-provider=s3)
  --s3-secret-access-key <sk>     AWS secret access key
  --s3-bucket <name>              S3 bucket name
  --s3-region <region>            AWS region (e.g. us-east-1)
  --gcs-bucket <name>             GCS bucket name (storage-provider=gcs)
  --gcs-project-id <id>           GCP project ID
  --gcs-key-file <path>           Path on this VM to a GCP service account JSON key file
  --domain <domain>               Domain name for HTTPS (e.g. vpn.example.com)
  --admin-email <email>           Email for Let's Encrypt (required with --domain)
  --install-docker                Install Docker automatically if not present
  --client-add-form-url <url>     URL shown instead of the Create button (default: Jira form)
  --client-add-enabled            Re-enable direct client creation in the UI
  --port-forward <lp:ip:dp>       Forward TCP <lp> on this VM to <ip>:<dp>. Repeatable.
                                  Example: --port-forward 8443:10.0.1.5:443
  --metrics-token <hex>           Enable the monitoring API at /api/v1/metrics/
                                  with this bearer token. Omit to keep the API disabled.
  --generate-metrics-token        Generate a random 64-char hex token and enable the API.
                                  The token is printed in the post-install summary.
EOF
  exit 20
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
    --storage-provider|--local-log-dir| \\
    --oss-access-key-id|--oss-access-key-secret|--oss-bucket|--oss-endpoint| \\
    --s3-access-key-id|--s3-secret-access-key|--s3-bucket|--s3-region| \\
    --gcs-bucket|--gcs-project-id|--gcs-key-file| \\
    --domain|--admin-email|--client-add-form-url|--port-forward|--metrics-token)
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
        --storage-provider --local-log-dir
        --oss-access-key-id --oss-access-key-secret --oss-bucket --oss-endpoint
        --s3-access-key-id --s3-secret-access-key --s3-bucket --s3-region
        --gcs-bucket --gcs-project-id --gcs-key-file
        --metrics-token --generate-metrics-token
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
  [[ "$(id -u)" -eq 0 ]] || err 22 "This script must be run as root: sudo $0 $*"
}

check_openvpn() {
  log "Checking for OpenVPN..."
  [[ -f "${OPENVPN_CONF_DIR}/server.conf" ]] || err 23 \
"OpenVPN server.conf not found at ${OPENVPN_CONF_DIR}/server.conf.
Please run angristan's installer first, then re-run this script:
  curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
  chmod +x openvpn-install.sh
  sudo bash openvpn-install.sh"
  log "OpenVPN found."
}

check_scripts_src() {
  [[ -d "$SCRIPTS_SRC" ]] || err 24 \
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
    apt_get update >/dev/null
    apt_get install -y --no-install-recommends ca-certificates curl gnupg >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt_get update >/dev/null
    apt_get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
    systemctl enable --now docker > /dev/null 2>&1
    log "Docker installed."
  else
    err 25 "Docker is required. Install it and re-run this script.
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

setup_disconnect_hook() {
  log "Checking client-disconnect hook..."
  local conf="${OPENVPN_CONF_DIR}/server.conf"
  local hook="${SCRIPTS_DST}/client-disconnect.sh"
  local changed=0

  if ! grep -qE "^script-security[[:space:]]+2" "$conf"; then
    sed -i '/^script-security /d' "$conf"
    echo "script-security 2" >> "$conf"
    changed=1
  fi
  if ! grep -qF "client-disconnect ${hook}" "$conf"; then
    sed -i '\#^client-disconnect #d' "$conf"
    echo "client-disconnect ${hook}" >> "$conf"
    changed=1
  fi

  if (( changed )); then
    log "Added client-disconnect hook to server.conf."
    systemctl restart openvpn-server@server
    log "OpenVPN restarted."
  else
    log "client-disconnect hook already configured — skipping."
  fi
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

setup_storage_local() {
  local dir="$1"
  log "Configuring local log archive storage at ${dir}..."
  mkdir -p "$dir"
  chmod 755 "$dir"
  log "Local archive directory ready."
}

setup_storage_oss() {
  local key_id="$1" key_secret="$2" endpoint="$3"
  log "Configuring Alibaba Cloud OSS storage..."
  "${SCRIPTS_DST}/setup-storage-oss.sh" "$key_id" "$key_secret" "$endpoint"
}

setup_storage_s3() {
  local key_id="$1" key_secret="$2" region="$3"
  log "Configuring AWS S3 storage..."
  "${SCRIPTS_DST}/setup-storage-s3.sh" "$key_id" "$key_secret" "$region"
}

setup_storage_gcs() {
  local src_key="$1" dest_key="$2"
  log "Configuring GCP Cloud Storage..."
  "${SCRIPTS_DST}/setup-storage-gcs.sh" "$src_key" "$dest_key"
}

setup_geoip() {
  log "Setting up MaxMind GeoLite2-City..."
  if ! command -v geoipupdate &>/dev/null; then
    apt_get update >/dev/null
    apt_get install -y --no-install-recommends geoipupdate >/dev/null
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
    apt_get update >/dev/null
    apt_get install -y --no-install-recommends certbot >/dev/null
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
  local geoip_path="${1:-}" storage_provider="${2:-local}" local_log_dir="${3:-$DEFAULT_LOCAL_LOG_DIR}"
  local oss_bucket="${4:-}" oss_endpoint="${5:-}"
  local s3_bucket="${6:-}" s3_region="${7:-}"
  local gcs_bucket="${8:-}" gcs_project="${9:-}" gcs_key_path="${10:-}"
  local tls_cert="${11:-}" tls_key="${12:-}"
  local client_add_disabled="${13:-true}" client_add_form_url="${14:-$DEFAULT_CLIENT_ADD_FORM_URL}"
  local metrics_token="${15:-}"

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
StorageProvider            = ${storage_provider}
LocalLogDir                = ${local_log_dir}
OSSLogBucket               = ${oss_bucket}
OSSEndpoint                = ${oss_endpoint}
S3LogBucket                = ${s3_bucket}
S3Region                   = ${s3_region}
GCSLogBucket               = ${gcs_bucket}
GCSProjectID               = ${gcs_project}
GCSServiceAccountKeyFile   = ${gcs_key_path}
ServerAddress              = ${server_ip}
ClientAddDisabled          = ${client_add_disabled}
ClientAddFormURL           = ${client_add_form_url}
MetricsAuthToken           = ${metrics_token}
MetricsCacheSeconds        = 5
DisconnectsWindowH         = 24
MetricsHashClientNames     = false
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
  local geoip_enabled="${3:-false}" storage_provider="${4:-local}" local_log_dir="${5:-$DEFAULT_LOCAL_LOG_DIR}"
  local domain="${6:-}" gcs_key_path="${7:-$DEFAULT_GCS_KEY_DEST}"

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
      - /var/log/openvpn:/var/log/openvpn
      - /etc/iptables:/etc/iptables
      - /etc/sysctl.d:/etc/sysctl.d
COMPOSE
    case "$storage_provider" in
      local) echo "      - ${local_log_dir}:${local_log_dir}" ;;
      oss)
        echo "      - /root/.ossutilconfig:/root/.ossutilconfig:ro"
        echo "      - /usr/bin/ossutil:/usr/bin/ossutil:ro"
        ;;
      s3)
        echo "      - /root/.aws:/root/.aws:ro"
        ;;
      gcs)
        echo "      - ${gcs_key_path}:${gcs_key_path}:ro"
        ;;
    esac
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
  DEBIAN_FRONTEND=noninteractive apt_get install -y iptables-persistent >/dev/null
  mkdir -p /etc/iptables
  log "iptables-persistent installed."
}

apply_port_forwards() {
  [[ ${#PORT_FORWARDS[@]} -eq 0 ]] && return 0
  local spec lp di dp
  for spec in "${PORT_FORWARDS[@]}"; do
    [[ "$spec" =~ ^[0-9]+:[0-9.]+:[0-9]+$ ]] \
      || err 28 "Invalid --port-forward spec '${spec}'. Expected <listen-port>:<dest-ip>:<dest-port>."
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
  local metrics_token="${1:-}"
  local server_ip
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

  echo ""
  echo "============================================================"
  echo "  VM setup complete."
  echo "============================================================"
  if [[ -n "$metrics_token" ]]; then
    echo ""
    echo "  Metrics API token (paste into your central monitor):"
    echo "    METRICS_TOKEN=${metrics_token}"
    echo "  Endpoints: GET https://${server_ip}:${UI_HTTPS_PORT}/api/v1/metrics/{summary,clients,disconnects,portforwards,certificates}"
    echo "  Authorization: Bearer ${metrics_token}"
    echo "============================================================"
  fi
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
  local admin_user="$1"        admin_pass="$2"
  local maxmind_id="$3"        maxmind_key="$4"
  local storage_provider="$5"  local_log_dir="$6"
  local oss_key_id="$7"        oss_key_secret="$8"
  local oss_bucket="$9"        oss_endpoint="${10}"
  local s3_key_id="${11}"      s3_key_secret="${12}"
  local s3_bucket="${13}"      s3_region="${14}"
  local gcs_bucket="${15}"     gcs_project="${16}"     gcs_src_key="${17}"
  local domain="${18}"         admin_email="${19}"
  local install_docker="${20:-false}"
  local client_add_disabled="${21:-true}"
  local client_add_form_url="${22:-$DEFAULT_CLIENT_ADD_FORM_URL}"
  local metrics_token="${23:-}"

  local geoip_path="" geoip_enabled="false"
  local gcs_key_dest="$DEFAULT_GCS_KEY_DEST"

  case "$storage_provider" in
    local|oss|s3|gcs) ;;
    *) err 30 "Unknown --storage-provider '${storage_provider}'. Supported: local, oss, s3, gcs." ;;
  esac
  if [[ "$storage_provider" == "oss" ]]; then
    [[ -n "$oss_key_id" && -n "$oss_key_secret" && -n "$oss_bucket" ]] \
      || err 31 "--storage-provider=oss requires --oss-access-key-id, --oss-access-key-secret, and --oss-bucket."
  fi
  if [[ "$storage_provider" == "s3" ]]; then
    [[ -n "$s3_key_id" && -n "$s3_key_secret" && -n "$s3_bucket" && -n "$s3_region" ]] \
      || err 32 "--storage-provider=s3 requires --s3-access-key-id, --s3-secret-access-key, --s3-bucket, and --s3-region."
  fi
  if [[ "$storage_provider" == "gcs" ]]; then
    [[ -n "$gcs_bucket" && -n "$gcs_src_key" ]] \
      || err 33 "--storage-provider=gcs requires --gcs-bucket and --gcs-key-file."
    [[ -f "$gcs_src_key" ]] \
      || err 34 "--gcs-key-file '${gcs_src_key}' not found."
  fi

  check_openvpn
  check_scripts_src
  maybe_install_docker "$install_docker"

  if ! command -v crontab &>/dev/null; then
    log "Installing cron..."
    apt_get install -y cron >/dev/null
    systemctl enable --now cron > /dev/null 2>&1
    log "cron installed."
  fi

  setup_directories
  setup_management_interface
  setup_disconnect_hook
  setup_pki_symlink
  setup_client_template
  install_scripts

  case "$storage_provider" in
    local)
      setup_storage_local "$local_log_dir"
      # Clear cloud fields so the cron rotation script doesn't try to upload.
      oss_bucket=""; oss_endpoint=""
      s3_bucket=""; s3_region=""
      gcs_bucket=""; gcs_project=""; gcs_key_dest=""
      ;;
    oss)
      setup_storage_oss "$oss_key_id" "$oss_key_secret" "$oss_endpoint"
      s3_bucket=""; s3_region=""
      gcs_bucket=""; gcs_project=""; gcs_key_dest=""
      ;;
    s3)
      setup_storage_s3 "$s3_key_id" "$s3_key_secret" "$s3_region"
      oss_bucket=""; oss_endpoint=""
      gcs_bucket=""; gcs_project=""; gcs_key_dest=""
      ;;
    gcs)
      setup_storage_gcs "$gcs_src_key" "$gcs_key_dest"
      oss_bucket=""; oss_endpoint=""
      s3_bucket=""; s3_region=""
      ;;
  esac

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

  write_app_conf "$geoip_path" "$storage_provider" "$local_log_dir" \
    "$oss_bucket" "$oss_endpoint" \
    "$s3_bucket" "$s3_region" \
    "$gcs_bucket" "$gcs_project" "$gcs_key_dest" \
    "$tls_cert" "$tls_key" \
    "$client_add_disabled" "$client_add_form_url" \
    "$metrics_token"
  write_compose "$admin_user" "$admin_pass" "$geoip_enabled" \
    "$storage_provider" "$local_log_dir" "$domain" "$gcs_key_dest"
  setup_cron
  setup_iptables_persistence
  apply_port_forwards
  print_next_steps "$metrics_token"
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

  # Log archive storage backend
  local storage_provider="local" local_log_dir="$DEFAULT_LOCAL_LOG_DIR"
  local oss_key_id="" oss_key_secret="" oss_bucket="" oss_endpoint="oss-me-central-1.aliyuncs.com"
  local s3_key_id="" s3_key_secret="" s3_bucket="" s3_region="us-east-1"
  local gcs_bucket="" gcs_project="" gcs_src_key=""
  echo ""
  echo "--- Log Archive Storage ---"
  echo "Where to store compressed OpenVPN session log archives (read by the audit log browser)."
  echo "  local — write archives to a directory on this VM (no credentials required)"
  echo "  oss   — upload archives to an Alibaba Cloud OSS bucket"
  echo "  s3    — upload archives to an AWS S3 bucket"
  echo "  gcs   — upload archives to a GCP Cloud Storage bucket"
  while true; do
    storage_provider=$(ask_value "Storage backend (local/oss/s3/gcs)" "local")
    storage_provider="${storage_provider,,}"
    case "$storage_provider" in
      local|oss|s3|gcs) break ;;
      *) warn "Choose 'local', 'oss', 's3', or 'gcs'." ;;
    esac
  done
  case "$storage_provider" in
    local)
      local_log_dir=$(ask_value "Local archive directory" "$DEFAULT_LOCAL_LOG_DIR")
      ;;
    oss)
      oss_key_id=$(ask_value "OSS Access Key ID")
      oss_key_secret=$(ask_value "OSS Access Key Secret" "" "true")
      oss_bucket=$(ask_value "OSS Bucket Name")
      oss_endpoint=$(ask_value "OSS Endpoint" "oss-me-central-1.aliyuncs.com")
      ;;
    s3)
      s3_key_id=$(ask_value "AWS Access Key ID")
      s3_key_secret=$(ask_value "AWS Secret Access Key" "" "true")
      s3_bucket=$(ask_value "S3 Bucket Name")
      s3_region=$(ask_value "AWS Region" "us-east-1")
      ;;
    gcs)
      gcs_bucket=$(ask_value "GCS Bucket Name")
      gcs_project=$(ask_value "GCP Project ID")
      while true; do
        gcs_src_key=$(ask_value "Path to GCP service-account JSON key on this VM")
        [[ -f "$gcs_src_key" ]] && break
        warn "File not found: ${gcs_src_key}"
      done
      ;;
  esac

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

  # Metrics API token — optional
  local metrics_token=""
  echo ""
  echo "--- Monitoring API (optional) ---"
  echo "A read-only JSON API at /api/v1/metrics/ for a central monitoring system."
  echo "If disabled, the namespace returns 404 (default-deny)."
  if ask_yn "Enable the monitoring API?"; then
    metrics_token="$(openssl rand -hex 32)"
    log "Generated metrics token (saved to app.conf): ${metrics_token}"
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
    "$admin_user"        "$admin_pass" \
    "$maxmind_id"        "$maxmind_key" \
    "$storage_provider"  "$local_log_dir" \
    "$oss_key_id"        "$oss_key_secret" "$oss_bucket" "$oss_endpoint" \
    "$s3_key_id"         "$s3_key_secret"  "$s3_bucket"  "$s3_region" \
    "$gcs_bucket"        "$gcs_project"    "$gcs_src_key" \
    "$domain"            "$admin_email" \
    "false" \
    "$client_add_disabled" "$client_add_form_url" \
    "$metrics_token"
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
  *)          err 21 "Unknown command: '${COMMAND}'. Run '$0' for usage." ;;
esac

# Non-interactive: parse flags
ADMIN_USER="admin"; ADMIN_PASS=""
MAXMIND_ID="";      MAXMIND_KEY=""
STORAGE_PROVIDER=""; LOCAL_LOG_DIR="$DEFAULT_LOCAL_LOG_DIR"
OSS_KEY_ID="";      OSS_KEY_SECRET=""; OSS_BUCKET=""; OSS_ENDPOINT="oss-me-central-1.aliyuncs.com"
S3_KEY_ID="";       S3_KEY_SECRET="";  S3_BUCKET="";  S3_REGION=""
GCS_BUCKET="";      GCS_PROJECT="";    GCS_KEY_FILE=""
DOMAIN="";          ADMIN_EMAIL=""
INSTALL_DOCKER="false"
CLIENT_ADD_DISABLED="true"; CLIENT_ADD_FORM_URL="$DEFAULT_CLIENT_ADD_FORM_URL"
METRICS_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-username)        ADMIN_USER="$2";       shift 2 ;;
    --admin-password)        ADMIN_PASS="$2";       shift 2 ;;
    --maxmind-account-id)    MAXMIND_ID="$2";       shift 2 ;;
    --maxmind-license-key)   MAXMIND_KEY="$2";      shift 2 ;;
    --storage-provider)      STORAGE_PROVIDER="${2,,}"; shift 2 ;;
    --local-log-dir)         LOCAL_LOG_DIR="$2";    shift 2 ;;
    --oss-access-key-id)     OSS_KEY_ID="$2";       shift 2 ;;
    --oss-access-key-secret) OSS_KEY_SECRET="$2";   shift 2 ;;
    --oss-bucket)            OSS_BUCKET="$2";       shift 2 ;;
    --oss-endpoint)          OSS_ENDPOINT="$2";     shift 2 ;;
    --s3-access-key-id)      S3_KEY_ID="$2";        shift 2 ;;
    --s3-secret-access-key)  S3_KEY_SECRET="$2";    shift 2 ;;
    --s3-bucket)             S3_BUCKET="$2";        shift 2 ;;
    --s3-region)             S3_REGION="$2";        shift 2 ;;
    --gcs-bucket)            GCS_BUCKET="$2";       shift 2 ;;
    --gcs-project-id)        GCS_PROJECT="$2";      shift 2 ;;
    --gcs-key-file)          GCS_KEY_FILE="$2";     shift 2 ;;
    --domain)                DOMAIN="$2";           shift 2 ;;
    --admin-email)           ADMIN_EMAIL="$2";      shift 2 ;;
    --install-docker)        INSTALL_DOCKER="true";                shift   ;;
    --client-add-form-url)   CLIENT_ADD_FORM_URL="$2";            shift 2 ;;
    --client-add-enabled)    CLIENT_ADD_DISABLED="false"; CLIENT_ADD_FORM_URL=""; shift ;;
    --metrics-token)         METRICS_TOKEN="$2";                  shift 2 ;;
    --generate-metrics-token) METRICS_TOKEN="$(openssl rand -hex 32)"; shift ;;
    --port-forward)
      [[ -n "${2:-}" ]] || err 27 "--port-forward requires <listen-port>:<dest-ip>:<dest-port>"
      PORT_FORWARDS+=("$2"); shift 2 ;;
    *) err 26 "Unknown flag: $1. Run '$0 install' with no flags to see usage." ;;
  esac
done

[[ -n "$ADMIN_PASS" ]] \
  || err 29 "--admin-password is required for non-interactive setup.
For a guided setup, use: sudo $0 init"

# Storage provider default: explicit flag wins; otherwise infer from provider-
# specific flags so existing scripts/integrations keep working; otherwise local.
if [[ -z "$STORAGE_PROVIDER" ]]; then
  if   [[ -n "$OSS_KEY_ID" || -n "$OSS_BUCKET" ]]; then STORAGE_PROVIDER="oss"
  elif [[ -n "$S3_KEY_ID"  || -n "$S3_BUCKET"  ]]; then STORAGE_PROVIDER="s3"
  elif [[ -n "$GCS_BUCKET" || -n "$GCS_KEY_FILE" ]]; then STORAGE_PROVIDER="gcs"
  else STORAGE_PROVIDER="local"
  fi
fi

run_install \
  "$ADMIN_USER"        "$ADMIN_PASS" \
  "$MAXMIND_ID"        "$MAXMIND_KEY" \
  "$STORAGE_PROVIDER"  "$LOCAL_LOG_DIR" \
  "$OSS_KEY_ID"        "$OSS_KEY_SECRET" "$OSS_BUCKET" "$OSS_ENDPOINT" \
  "$S3_KEY_ID"         "$S3_KEY_SECRET"  "$S3_BUCKET"  "$S3_REGION" \
  "$GCS_BUCKET"        "$GCS_PROJECT"    "$GCS_KEY_FILE" \
  "$DOMAIN"            "$ADMIN_EMAIL" \
  "$INSTALL_DOCKER" \
  "$CLIENT_ADD_DISABLED" "$CLIENT_ADD_FORM_URL" \
  "$METRICS_TOKEN"
