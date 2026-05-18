#!/usr/bin/env bash
#
# setup-storage-s3.sh
# Installs the AWS CLI v2 and writes ~/.aws/credentials and ~/.aws/config for
# the openvpn-ui AWS S3 storage backend. Called by host/setup.sh when
# StorageProvider=s3. The credentials file is also mounted into the openvpn-ui
# container so the Go SDK (aws-sdk-go-v2) picks them up via the default chain.
#
# Usage:
#   sudo setup-storage-s3.sh <access-key-id> <secret-access-key> <region>

set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Must run as root" >&2; exit 96; }
[[ $# -eq 3 ]] || { echo "Usage: $0 <access-key-id> <secret-access-key> <region>" >&2; exit 97; }

AWS_KEY_ID="$1"
AWS_KEY_SECRET="$2"
AWS_REGION="$3"

if ! command -v aws &>/dev/null; then
  echo "[INFO] Installing AWS CLI v2..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq --no-install-recommends curl unzip >/dev/null 2>&1
  arch="$(uname -m)"
  case "$arch" in
    x86_64) zip="awscli-exe-linux-x86_64.zip" ;;
    aarch64) zip="awscli-exe-linux-aarch64.zip" ;;
    *) echo "Unsupported arch: ${arch}" >&2; exit 98 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/${zip}" -o "${tmp}/awscli.zip"
  unzip -q "${tmp}/awscli.zip" -d "${tmp}"
  "${tmp}/aws/install" >/dev/null 2>&1
  rm -rf "${tmp}"
  echo "[INFO] AWS CLI installed."
else
  echo "[INFO] AWS CLI already installed."
fi

mkdir -p /root/.aws
cat > /root/.aws/credentials <<AWSCREDS
[default]
aws_access_key_id     = ${AWS_KEY_ID}
aws_secret_access_key = ${AWS_KEY_SECRET}
AWSCREDS
chmod 600 /root/.aws/credentials

cat > /root/.aws/config <<AWSCONF
[default]
region = ${AWS_REGION}
output = json
AWSCONF
chmod 600 /root/.aws/config

echo "[INFO] AWS credentials written to /root/.aws/"
