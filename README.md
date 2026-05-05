# openvpn-ui

A web interface for managing an OpenVPN server, with added support for
Alibaba Cloud OSS log archiving, an audit log browser, GeoIP enrichment,
and an improved map view.

This is a fork of [d3vilh/openvpn-ui](https://github.com/d3vilh/openvpn-ui).
All credit for the original work goes to the upstream author. This fork
extends it with production-oriented features specific to our deployment.

---

## What is added in this fork

**Audit log browser** (`/logs/browse`)
- Reads archived OpenVPN session logs from an Alibaba Cloud OSS bucket
- Filters by date and by user CN
- Shows connect time, disconnect time, session duration, and source location
- Exports filtered results as CSV

**Automatic log archiving**
- A host cron job collects OpenVPN journal lines into a rolling master log
- A second job compresses and uploads the master log to OSS daily at 23:59 UTC,
  or earlier if the log exceeds 10 MB
- Archives are named `openvpn-logs-YYYY-MM-DD-HHmmss.log.gz`

**GeoIP enrichment**
- Audit log sessions show city and country resolved from the client source IP
- Map view shows the same for connected clients
- Powered by the MaxMind GeoLite2-City database

**Improved map view** (`/map`)
- Clients that disconnected within the last 4 hours appear as faded markers
  alongside currently connected clients
- Clicking a faded marker shows the CN, location, disconnect time, and duration

---

## Setup

### What you need

**On the VM (your VPN server):**
- A fresh Ubuntu 22.04 or 24.04 server (1–2 vCPU, 1 GB RAM is enough to run)
- Root or sudo access

**On your local machine:**
- Docker installed (to build the image — the VM doesn't have enough RAM to build)
- Git
- SSH access to the VM

**Optional, for extra features:**
- A free [MaxMind account](https://www.maxmind.com) — enables the map view
- An Alibaba Cloud OSS bucket with a RAM user — enables audit log backup
- A domain name pointed at the VM — enables HTTPS

---

### Step 1 — Clone this repository

Do this on **both** the VM and your local machine.

```bash
git clone https://github.com/aliAljaffer/openvpn-ui.git
cd openvpn-ui
```

---

### Step 2 — Install OpenVPN on the VM

SSH into your VM and run [angristan/openvpn-install](https://github.com/angristan/openvpn-install):

```bash
curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
sudo bash openvpn-install.sh install \
  --port 1194 \
  --client-cert-days 60 \
  --server-cert-days 730 \
  --tls-sig crypt-v2 \
  --no-client
```

> **Why these flags?**
> - `--port 1194` — sets the VPN port explicitly. You will need to open this port
>   (UDP) in your firewall or cloud security group for clients to connect.
> - `--client-cert-days 60` / `--server-cert-days 730` — the installer defaults
>   to 10-year certificates. These give 60 days for client certs and 2 years for
>   the server cert.
> - `--tls-sig crypt-v2` — required for per-client tls-crypt-v2 keys, which
>   our client scripts generate and embed in each `.ovpn` file.
> - `--no-client` — skip the initial test client; openvpn-ui manages clients.

When the installer finishes, OpenVPN will be running as a systemd service.

> **Note:** The installer configures the management interface as a Unix socket
> by default. `setup.sh` (next step) detects this and switches it to TCP
> automatically.

---

### Step 3 — Run the setup script on the VM

Still on the VM, inside the cloned repository:

```bash
cd openvpn-ui
sudo ./host/setup.sh init
```

This is an interactive guided setup. It will ask you:

1. **Admin username and password** — for logging into the web UI
2. **Map view** — whether to enable it (requires a MaxMind account)
3. **Audit log backup** — whether to enable it (requires an OSS bucket)
4. **HTTPS** — whether to enable it (requires a domain name pointed at the VM)

Everything is optional except the password. If you skip map view or audit
logs, those features are simply disabled — nothing else is affected.

> **If you enable HTTPS:** `setup.sh` uses Let's Encrypt to issue the certificate.
> Let's Encrypt validates domain ownership by making an HTTP request to your VM
> on **port 80**. Open port 80 in your firewall or cloud security group before
> running `setup.sh`, then close it again once the certificate has been issued.
> Port 80 is only needed during initial issuance and renewals — not for normal
> UI operation.

When it finishes, you will see a message telling you to run `deploy.sh` from
your local machine. Exit the SSH session.

> If you prefer non-interactive setup, use `sudo ./host/setup.sh install --help`
> to see all available flags.

---

### Step 4 — Build and deploy the image

Back on **your local machine**, inside the cloned repository:

```bash
./host/deploy.sh --vm-ip YOUR_VM_IP
```

If your VM uses a non-default SSH key:

```bash
./host/deploy.sh --vm-ip YOUR_VM_IP --vm-ssh-key ~/.ssh/your_key
```

This will:
1. Build the Docker image for `linux/amd64`
2. Compress and upload it to the VM
3. Load it and start the container

The first build takes a few minutes. Subsequent deploys are the same process —
just run `deploy.sh` again after making changes.

---

### Step 5 — Open the UI

Before navigating to the UI, make sure the relevant port is open on the VM.

**If using a cloud provider security group** (Alibaba Cloud, AWS, GCP, etc.),
add an inbound rule for the port in your console.

**If using ufw on the VM:**
```bash
# HTTP only
sudo ufw allow 8080/tcp

# HTTPS only (if you configured a domain in Step 3)
sudo ufw allow 8443/tcp
```

Open only one — whichever matches your setup:

| Setup | Open | Keep closed |
|---|---|---|
| HTTP only | 8080 | 8443 |
| HTTPS | 8443 | 8080 |

> **Note:** The container also binds an internal port (8088) used by the Beego
> framework. Never open this externally.

Then navigate to:
- HTTP: `http://YOUR_VM_IP:8080`
- HTTPS: `https://YOUR_DOMAIN:8443`

Log in with the admin credentials you set in Step 3.

To verify the container is running:

```bash
ssh root@YOUR_VM_IP 'sudo docker logs openvpn-ui --tail 20'
```

---

## Configuration reference

### conf/app.conf

Located at `/opt/openvpn-ui/conf/app.conf` on the VM. Written by `setup.sh` —
you can edit it manually and restart the container to apply changes.

```ini
AppName                    = openvpn-ui
HttpPort                   = 8080
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
GeoipDbPath                = /usr/share/GeoIP/GeoLite2-City.mmdb
OVClientsDir               = "/root"
OSSLogBucket               = your-bucket-name
OSSEndpoint                = oss-me-central-1.aliyuncs.com
```

Key settings:

- `GeoipDbPath` — leave empty to disable the map view and geo lookup in audit logs
- `OSSLogBucket` — leave empty to disable audit log backup and the log browser
- `OpenVpnManagementAddress` — must match the `management` line in `server.conf`

Optional TLS settings (added by `setup.sh` when a domain is configured):

```ini
EnableHTTPS                = true
HTTPSPort                  = 8443
HTTPSCertFile              = /etc/letsencrypt/live/vpn.example.com/fullchain.pem
HTTPSKeyFile               = /etc/letsencrypt/live/vpn.example.com/privkey.pem
```

### docker-compose.yml

Located at `/opt/openvpn-ui/docker-compose.yml`. Written by `setup.sh`.
Angristan's OpenVPN config lives under `/etc/openvpn/server/`, which is
bind-mounted into the container as `/etc/openvpn/`:

```yaml
services:
  openvpn-ui:
    image: openvpn-ui-local:latest
    container_name: openvpn-ui
    environment:
      - OPENVPN_ADMIN_USERNAME=admin
      - OPENVPN_ADMIN_PASSWORD=yourpassword
    network_mode: host
    volumes:
      - /etc/openvpn/server:/etc/openvpn
      - /etc/openvpn/server/easy-rsa:/usr/share/easy-rsa
      - /opt/openvpn-ui/db:/opt/openvpn-ui/db
      - /opt/openvpn-ui/conf:/opt/openvpn-ui/conf
      - /opt/scripts:/opt/scripts
      - /root:/root
      - /root/.ossutilconfig:/root/.ossutilconfig:ro   # if OSS enabled
      - /usr/share/GeoIP:/usr/share/GeoIP:ro           # if map view enabled
    restart: always
```

### OSS RAM user permissions

The RAM user supplied to `setup.sh` needs the following policy attached,
scoped to your bucket. Create it in the Alibaba Cloud console under
RAM → Policies → Create Policy (JSON tab), then attach it to the RAM user.

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "oss:ListObjects"
      ],
      "Resource": [
        "acs:oss:*:*:your-bucket-name"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "oss:PutObject",
        "oss:GetObject",
        "oss:DeleteObject"
      ],
      "Resource": [
        "acs:oss:*:*:your-bucket-name/*"
      ]
    }
  ]
}
```

Replace `your-bucket-name` with your actual bucket name.

| Permission | Used by |
|---|---|
| `oss:ListObjects` | Log browser — lists available archives |
| `oss:GetObject` | Log browser — downloads an archive to parse it |
| `oss:PutObject` | Log rotation cron — uploads compressed log archives |
| `oss:DeleteObject` | OSS SDK smoke test (`go run ./cmd/osstest`) |

`oss:DeleteObject` is only needed if you run the smoke test. It can be omitted
from the production policy if preferred.

### OSS credentials

`/root/.ossutilconfig` on the VM (written by `setup.sh`, mode 600).
Read by both the container (for the audit log browser) and the host cron job
(for log uploads):

```ini
[Credentials]
language=EN
accessKeyID=YOUR_ACCESS_KEY_ID
accessKeySecret=YOUR_ACCESS_KEY_SECRET
endpoint=oss-me-central-1.aliyuncs.com
```

### Cron jobs

`setup.sh` installs these automatically.

`/etc/cron.d/openvpn-logs`:
```
* * * * *   root /opt/scripts/ovpn-log-collect.sh
*/5 * * * * root /opt/scripts/ovpn-log-rotate.sh
59 23 * * * root /opt/scripts/ovpn-log-rotate.sh --eod
59 23 * * * root [ -f /run/openvpn-restart-pending ] && rm -f /run/openvpn-restart-pending && systemctl restart openvpn-server@server
```

Per-user crontab (for the Logs page):
```
* * * * * journalctl -n 300 -xeu openvpn-server@server.service --no-pager > /opt/scripts/ovpn-logs.txt 2>&1
```

The last cron entry in `/etc/cron.d/openvpn-logs` runs a pending OpenVPN
restart at 23:59 if a certificate was revoked during the day. This deferred
approach avoids disconnecting other active sessions mid-day.

---

## Feature notes

**Audit log browser — no events found**

If an archive shows "no events found", verify the log was collected with
`journalctl -o short-iso`. The parser expects lines in this format:

```
2026-04-15T14:49:28+0800 hostname openvpn[pid]: message
```

**Recently disconnected map markers**

The map reads `/opt/scripts/ovpn-master.log` for sessions that ended within
the last 4 hours. If the master log is empty after a rotation, restore the
most recent archive to repopulate it:

```bash
ossutil cp oss://your-bucket/openvpn-logs-YYYY-MM-DD-HHmmss.log.gz /tmp/r.log.gz \
  --endpoint oss-me-central-1.aliyuncs.com -f
zcat /tmp/r.log.gz > /opt/scripts/ovpn-master.log
```

**OSS SDK smoke test**

`cmd/osstest/main.go` verifies upload, list, download, and delete against
your real bucket using credentials from `/root/.ossutilconfig`:

```bash
go run ./cmd/osstest
```

---

## Future plans

**Pluggable log storage (local, OSS, S3, GCS)**

Log archiving and the audit log browser currently require Alibaba Cloud OSS.
The plan is to make the storage backend pluggable: local VM filesystem (the new
default — no credentials required), Alibaba Cloud OSS, AWS S3, and GCP Cloud
Storage. The archive format and browser experience will be identical regardless
of where the logs live.

---

**Multi-cloud provisioning (AWS EC2 and GCP Compute Engine)**

The bootstrap scripts currently target Alibaba Cloud ECS only. The plan is to add
AWS EC2 and GCP Compute Engine as provisioning targets behind a `--provider` flag.
Each provider gets its own script (`bootstrap-aws.sh`, `bootstrap-gcp.sh`) with the
same idempotent, named-resource approach. Minimal IAM / IAM role definitions will
be provided for each so you know exactly what permissions to grant before running.
The VM-side setup (`host/setup.sh`) and the local build-and-deploy flow (`host/deploy.sh`)
are already cloud-agnostic and will work unchanged across all three providers.

---

**Cloud provider startup script (user-data) support**

Cloud providers (Alibaba Cloud ECS, AWS EC2, GCP Compute Engine) all support
passing an initialization script that runs automatically on the instance's first
boot via user-data / cloud-init. The plan is to produce a version of `host/setup.sh`
that can be embedded directly as a startup script, so the VM configures itself
on first boot with no SSH step required. The Docker image would still be built
locally and transferred after the instance is ready, keeping the RAM constraint
in check. This would allow fully hands-off provisioning: spin up the VM, wait
for it to signal readiness, then run `deploy.sh`.

---

## Building locally

```bash
# For the host architecture (development and testing):
go build ./...

# For the VM (linux/amd64) — done automatically by deploy.sh:
docker build --platform linux/amd64 -t openvpn-ui-local:latest .
```

Dependencies are managed with Go modules. The `vendor/` directory is excluded
from git — Docker recreates it from `go.mod` and `go.sum` at build time.
