#!/usr/bin/env bash
#
# deploy.sh
# Builds the openvpn-ui Docker image on your LOCAL machine and deploys it to the VM.
# Run this from your local machine AFTER running setup.sh on the VM.
#
# Usage:
#   ./deploy.sh --vm-ip <IP> [OPTIONS]
#   ./deploy.sh completion
#
# Options:
#   --vm-ip <IP>          VM IP address or hostname (required)
#   --vm-user <user>      SSH user (default: root)
#   --vm-ssh-key <path>   Path to SSH private key (optional)
#   --src-dir <path>      Path to openvpn-ui source directory
#                         (default: parent of the host/ directory)
#   --skip-build          Skip the Docker build step (reuse the last built image)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SRC_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 --vm-ip <IP> [OPTIONS]
  $0 completion

Options:
  --vm-ip <IP>          VM IP address or hostname (required)
  --vm-user <user>      SSH user (default: root)
  --vm-ssh-key <path>   Path to SSH private key (optional)
  --src-dir <path>      Path to openvpn-ui source directory
                        (default: ${DEFAULT_SRC_DIR})
  --skip-build          Skip the Docker build step (reuse the last built image)
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
# Enable with: source <(./${script_name} completion)

_deploy_openvpn_ui() {
  local cur prev
  cur="\${COMP_WORDS[COMP_CWORD]}"
  prev="\${COMP_WORDS[COMP_CWORD-1]}"

  case "\$prev" in
    --vm-ip|--vm-user) return 0 ;;
    --vm-ssh-key|--src-dir)
      COMPREPLY=( \$(compgen -f -- "\$cur") )
      return 0 ;;
  esac

  if [[ "\$cur" == -* ]]; then
    COMPREPLY=( \$(compgen -W "
      --vm-ip --vm-user --vm-ssh-key --src-dir --skip-build
    " -- "\$cur") )
  else
    COMPREPLY=( \$(compgen -W "completion" -- "\$cur") )
  fi
}

complete -F _deploy_openvpn_ui ${script_name}
complete -F _deploy_openvpn_ui ./${script_name}
COMPLETION
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
[[ $# -eq 0 ]] && usage
[[ "$1" == "completion" ]] && { print_completion; exit 0; }
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

VM_IP=""
VM_USER="root"
VM_SSH_KEY=""
SRC_DIR="$DEFAULT_SRC_DIR"
SKIP_BUILD="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)       VM_IP="$2";        shift 2 ;;
    --vm-user)     VM_USER="$2";      shift 2 ;;
    --vm-ssh-key)  VM_SSH_KEY="$2";   shift 2 ;;
    --src-dir)     SRC_DIR="$2";      shift 2 ;;
    --skip-build)  SKIP_BUILD="true"; shift   ;;
    completion)    print_completion;  exit 0  ;;
    -h|--help)     usage ;;
    *)             err "Unknown option: $1. Run '$0' for usage." ;;
  esac
done

[[ -n "$VM_IP" ]]   || err "--vm-ip is required."
[[ -d "$SRC_DIR" ]] || err "Source directory not found: ${SRC_DIR}"
command -v docker &>/dev/null || err "Docker is not installed on this machine. Install it from https://docs.docker.com/get-docker/"

# Build SSH/SCP option strings
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
[[ -n "$VM_SSH_KEY" ]] && SSH_OPTS="${SSH_OPTS} -i ${VM_SSH_KEY}"

remote() { ssh ${SSH_OPTS} "${VM_USER}@${VM_IP}" "$@"; }
scopy()  { scp ${SSH_OPTS} "$@"; }

# 1. Build the image locally for linux/amd64
if [[ "$SKIP_BUILD" == "true" ]]; then
  docker image inspect openvpn-ui-local:latest &>/dev/null \
    || err "No local image found. Run without --skip-build first."
  log "Skipping build — reusing existing local image."
else
  log "Building openvpn-ui image for linux/amd64..."
  log "Source: ${SRC_DIR}"
  docker build --platform linux/amd64 --progress=quiet -t openvpn-ui-local:latest "$SRC_DIR"
  log "Image built."
fi

# 2. Save and compress
ARCHIVE="/tmp/openvpn-ui-$$.tar.gz"
log "Saving image to archive..."
docker save openvpn-ui-local:latest | gzip > "$ARCHIVE"
SIZE_MB=$(du -m "$ARCHIVE" | awk '{print $1}')
log "Archive: ${ARCHIVE} (${SIZE_MB} MB)"

# 3. Upload to VM
log "Uploading to ${VM_USER}@${VM_IP}..."
scopy "$ARCHIVE" "${VM_USER}@${VM_IP}:/tmp/openvpn-ui-local.tar.gz"
rm -f "$ARCHIVE"
log "Upload complete."

# 4. Load image and restart container on the VM
log "Loading image and restarting container on VM..."
remote bash -s <<'REMOTE'
set -euo pipefail
echo "[INFO]  Loading Docker image..."
sudo docker load < /tmp/openvpn-ui-local.tar.gz > /dev/null
echo "[INFO]  Copying config templates from image..."
CID=$(sudo docker create openvpn-ui-local:latest)
for tpl in openvpn-client-config.tpl openvpn-server-config.tpl easyrsa-vars.tpl; do
  sudo docker cp "$CID":/opt/openvpn-ui/conf/"$tpl" /opt/openvpn-ui/conf/"$tpl"
done
sudo docker rm "$CID" > /dev/null
echo "[INFO]  Restarting container..."
sudo docker compose -f /opt/openvpn-ui/docker-compose.yml up -d --force-recreate > /dev/null 2>&1
rm -f /tmp/openvpn-ui-local.tar.gz
echo "[INFO]  Done."
REMOTE

echo ""
echo "============================================================"
echo "  Deployment complete"
echo "============================================================"
echo "  VM: ${VM_IP}"
echo ""
echo "  To verify the container started correctly, run:"
echo "    ssh ${VM_USER}@${VM_IP} 'sudo docker logs openvpn-ui --tail 20'"
echo "============================================================"
