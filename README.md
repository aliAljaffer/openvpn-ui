# openvpn-ui

A web interface for managing an OpenVPN server, with added support for
pluggable log archive storage, an audit log browser, GeoIP enrichment,
and an improved map view.

This is a fork of [d3vilh/openvpn-ui](https://github.com/d3vilh/openvpn-ui).
All credit for the original work goes to the upstream author. This fork
extends it with production-oriented features specific to our deployment.

---

## What is added in this fork

**Audit log browser** (`/logs/browse`)
- Reads archived OpenVPN session logs from the configured storage backend
- Filters by date and by user CN
- Shows connect time, disconnect time, session duration, and source location
- Exports filtered results as CSV

**Automatic log archiving**
- A host cron job collects OpenVPN journal lines into a rolling master log
- A second job compresses the master log and stores the archive in the
  configured backend daily at 23:59 UTC, or earlier if the log exceeds 10 MB
- Archives are named `openvpn-logs-YYYY-MM-DD-HHmmss.log.gz`

**Pluggable archive storage**
- `local` (default) — stores `.log.gz` archives on the VM filesystem.
  Zero credentials, works out of the box. Default path is
  `/var/log/openvpn-ui/archives` (override with `--local-log-dir`).
  Disk usage is negligible in practice — ~14 kB/day in real-world use.
- `oss` — uploads archives to an Alibaba Cloud OSS bucket. Requires a RAM
  user (see permissions below).
- Backend is selected via `--storage-provider local|oss` in `setup.sh`,
  or by editing `StorageProvider` in `app.conf` and restarting the container.
  The audit log browser and the rotation script both honor this setting.

**GeoIP enrichment**
- Audit log sessions show city and country resolved from the client source IP
- Map view shows the same for connected clients
- Powered by the MaxMind GeoLite2-City database

**Improved map view** (`/map`)
- Clients that disconnected within the last 4 hours appear as faded markers
  alongside currently connected clients
- Clicking a faded marker shows the CN, location, disconnect time, and duration

**TCP port forwarding** (`host/scripts/port-forward.sh` + web UI at `/portforward`)
- Forwards TCP traffic on a chosen listen port of the VPN VM to an internal
  `<ip>:<port>`, useful when VPN clients need access to an intranet service
  that isn't reachable any other way
- Persistent across reboots (iptables-persistent + `/etc/sysctl.d`)
- Multiple rules supported, identified by listen port for idempotency
- Three management surfaces, all backed by the same script:
  - During setup via `setup.sh --port-forward` (repeatable)
  - On the VM via `port-forward.sh add|list|remove`
  - In the browser at `Configuration → Port forwarding` (the web UI shells out
    to `port-forward.sh` so CLI and UI never disagree)

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
- An Alibaba Cloud OSS bucket with a RAM user — only if you want cloud-backed
  log archive storage; otherwise the local backend is used and needs nothing
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
3. **Log archive storage backend** — `local` (default, no credentials) or `oss`
   (Alibaba Cloud OSS bucket). Both feed the same audit log browser.
4. **Client creation** — whether direct creation is enabled in the UI, or
   whether the Create button is replaced by a link to an external request form
5. **Port forwarding** — optional TCP port-forward rules from the VPN VM to
   internal `<ip>:<port>` destinations
6. **HTTPS** — whether to enable it (requires a domain name pointed at the VM)

Everything is optional except the password. If you skip the map view those
features are simply disabled — nothing else is affected. The log archive
backend always has a working default (`local`).

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
StorageProvider            = local
LocalLogDir                = /var/log/openvpn-ui/archives
OSSLogBucket               =
OSSEndpoint                = oss-me-central-1.aliyuncs.com
```

Key settings:

- `GeoipDbPath` — leave empty to disable the map view and geo lookup in audit logs
- `StorageProvider` — `local` or `oss`. Selects where rotated `.log.gz` archives
  are written and where the audit log browser reads from. If unset and
  `OSSLogBucket` is non-empty, defaults to `oss` for backwards compatibility;
  otherwise defaults to `local`.
- `LocalLogDir` — archive directory used by the `local` backend
- `OSSLogBucket` — bucket name used by the `oss` backend (ignored for `local`)
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
      # Storage backend (one of):
      - /var/log/openvpn-ui/archives:/var/log/openvpn-ui/archives   # StorageProvider=local
      - /root/.ossutilconfig:/root/.ossutilconfig:ro                # StorageProvider=oss
      - /usr/share/GeoIP:/usr/share/GeoIP:ro                        # if map view enabled
    restart: always
```

### OSS RAM user permissions (only when `StorageProvider=oss`)

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

**Port forwarding**

You can configure rules either during initial VM setup or at any later point.

During setup — pass `--port-forward <listen-port>:<dest-ip>:<dest-port>` to
`setup.sh install` (repeatable), or answer the port-forwarding question when
running `setup.sh init`:

```bash
sudo ./host/setup.sh install --admin-password ... \
  --port-forward 8443:10.0.1.5:443 \
  --port-forward 9090:10.0.1.6:9090
```

After setup — run the management script directly on the VM:

```bash
sudo /opt/scripts/port-forward.sh add 8443 10.0.1.5 443
sudo /opt/scripts/port-forward.sh list
sudo /opt/scripts/port-forward.sh remove 8443
```

…or use the web UI at `Configuration → Port forwarding` for the same operations
in the browser. The web UI shells out to `port-forward.sh` so the script remains
the single source of truth — adding a rule via the UI and listing it on the VM
will always agree.

The iptables NAT rules persist across reboots via `iptables-persistent`, and
IPv4 forwarding is persisted in `/etc/sysctl.d/99-openvpn-forward.conf`. To make
the web UI able to mutate iptables, the openvpn-ui container is granted
`cap_add: NET_ADMIN` and bind-mounts `/etc/iptables` and `/etc/sysctl.d` from
the host (configured automatically by `setup.sh`). The container does **not**
run privileged.

> **Cloud security group:** these rules act on packets *after* they reach the
> VM, so they only matter once the listen port is allowed in. Open the listen
> port in your cloud provider's security group / firewall before adding a
> port-forward rule.

> **Reserved listen ports in the UI:** the web form refuses listen ports below
> 2000 (well-known/system range), the SSH port (22), the openvpn-ui ports
> (8080, 8443), and the OpenVPN server port. The CLI is intentionally permissive
> — these guardrails apply only when adding a rule from the browser.

---

## Future plans

**More log storage backends (S3, GCS)**

Local filesystem and Alibaba Cloud OSS are supported today. The plan is to
extend the storage backend interface to AWS S3 and GCP Cloud Storage so the
same audit log browser works against any of the four. The archive format and
browser experience stay identical regardless of where the logs live.

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

**Centralized monitoring API**

A read-only HTTP API on the openvpn-ui app that exposes live VPN telemetry —
connected clients, recent disconnects, current port-forward rules, certificate
inventory — for consumption by an internal central dashboard that aggregates
across multiple VPN VMs. JSON over the existing HTTPS listener, gated by a
single bearer token. Default-deny: until a token is configured the API
returns 404, so the surface is invisible until you opt in.

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
