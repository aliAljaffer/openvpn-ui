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
- `s3` — uploads archives to an AWS S3 bucket. Requires an IAM user/role
  (see `host/aws-s3-iam-policy.json`).
- `gcs` — uploads archives to a GCP Cloud Storage bucket. Requires a service
  account with a bucket-scoped role (see `host/gcs-bucket-role.yaml`).
- Backend is selected via `--storage-provider local|oss|s3|gcs` in `setup.sh`,
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

**Monitoring API** (`/api/v1/metrics/`)
- Read-only JSON + Prometheus exposition for centralized monitoring
- Endpoints: `summary`, `clients`, `disconnects`, `portforwards`, `certificates`, `prometheus`
- Token-gated (`Authorization: Bearer …`); default-deny returns 404 when no token is set
- See [Monitoring API](#monitoring-api) below

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

> **Setting up on a specific cloud?** Follow the end-to-end provisioning
> walkthrough for your provider instead of the generic steps below:
> - **[SETUP-ALIBABA.md](./SETUP-ALIBABA.md)** — Alibaba Cloud ECS
> - **[SETUP-GCP.md](./SETUP-GCP.md)** — Google Cloud Compute Engine
>
> The steps below are the generic, provider-agnostic path for a VM you already
> have (bare-metal, on-prem, or any other cloud).

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
- A cloud-bucket store for log archives — only if you want cloud-backed
  log archive storage; otherwise the local backend is used and needs nothing.
  Supported: Alibaba Cloud OSS, AWS S3, or GCP Cloud Storage.
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
3. **Log archive storage backend** — `local` (default, no credentials),
   `oss` (Alibaba Cloud OSS), `s3` (AWS S3), or `gcs` (GCP Cloud Storage).
   All four feed the same audit log browser.
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
S3LogBucket                =
S3Region                   =
GCSLogBucket               =
GCSProjectID               =
GCSServiceAccountKeyFile   =
MetricsAuthToken           =
MetricsCacheSeconds        = 5
DisconnectsWindowH         = 24
MetricsHashClientNames     = false
```

Key settings:

- `GeoipDbPath` — leave empty to disable the map view and geo lookup in audit logs
- `StorageProvider` — `local`, `oss`, `s3`, or `gcs`. Selects where rotated
  `.log.gz` archives are written and where the audit log browser reads from.
  If unset and `OSSLogBucket` is non-empty, defaults to `oss` for backwards
  compatibility; otherwise defaults to `local`.
- `LocalLogDir` — archive directory used by the `local` backend
- `OSSLogBucket` / `OSSEndpoint` — used by the `oss` backend
- `S3LogBucket` / `S3Region` — used by the `s3` backend. Credentials are read
  from the standard AWS chain (`/root/.aws/credentials` on the VM, mounted
  read-only into the container).
- `GCSLogBucket` / `GCSServiceAccountKeyFile` — used by the `gcs` backend.
  The key file is mounted read-only into the container at the same path.
  `GCSProjectID` is informational (the Go SDK derives the project from the
  service-account JSON).
- `OpenVpnManagementAddress` — must match the `management` line in `server.conf`
- `MetricsAuthToken` — empty disables the monitoring API (default-deny: the
  whole `/api/v1/metrics/` namespace returns 404). Set to a 64-character hex
  string to enable; clients then authenticate with `Authorization: Bearer …`.
  Use `setup.sh --generate-metrics-token` to mint one.
- `MetricsCacheSeconds` — in-process cache window for `/summary` and `/clients`
  (the only endpoints that hit the OpenVPN management socket). 0 disables.
- `DisconnectsWindowH` — default lookback for `/disconnects` (overridable per
  request with `?window=Nh`).
- `MetricsHashClientNames` — when `true`, CNs in metrics responses (including
  Prometheus labels) are replaced with an 8-byte SHA-256 prefix.

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
      # Storage backend (exactly one is mounted, chosen by StorageProvider):
      - /var/log/openvpn-ui/archives:/var/log/openvpn-ui/archives    # local
      - /root/.ossutilconfig:/root/.ossutilconfig:ro                 # oss
      - /root/.aws:/root/.aws:ro                                     # s3
      - /etc/openvpn-ui/gcs-sa-key.json:/etc/openvpn-ui/gcs-sa-key.json:ro  # gcs
      - /usr/share/GeoIP:/usr/share/GeoIP:ro                         # if map view enabled
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

### AWS S3 IAM policy (only when `StorageProvider=s3`)

The IAM user/role supplied to `setup.sh` needs the following policy attached,
scoped to your bucket. A ready-to-paste version with placeholders is shipped at
`host/aws-s3-iam-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OpenvpnUiBucketScopedListing",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Sid": "OpenvpnUiObjectIO",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    }
  ]
}
```

Replace `YOUR_BUCKET_NAME` with your actual bucket name.

| Permission | Used by |
|---|---|
| `s3:ListBucket` | Log browser — lists available archives |
| `s3:GetBucketLocation` | AWS SDK — region discovery |
| `s3:GetObject` | Log browser — downloads an archive to parse it |
| `s3:PutObject` | Log rotation cron — uploads compressed log archives |
| `s3:DeleteObject` | Only needed if you keep a smoke-test command around |

`s3:DeleteObject` can be omitted from the production policy if you don't run
a delete-style smoke test.

### GCS bucket role (only when `StorageProvider=gcs`)

The service account whose JSON key file is supplied to `setup.sh` needs
object-level access on the bucket. The shipped role definition at
`host/gcs-bucket-role.yaml` defines a custom role with exactly the
permissions needed. The simpler shortcut is to grant the predefined role
`roles/storage.objectAdmin` to the service account, scoped to the bucket
(not project-wide).

Custom role (recommended):

```bash
gcloud iam roles create openvpnUiLogArchive \
  --project=YOUR_GCP_PROJECT_ID \
  --file=host/gcs-bucket-role.yaml

gcloud storage buckets add-iam-policy-binding gs://YOUR_BUCKET_NAME \
  --member=serviceAccount:openvpn-ui@YOUR_GCP_PROJECT_ID.iam.gserviceaccount.com \
  --role=projects/YOUR_GCP_PROJECT_ID/roles/openvpnUiLogArchive
```

Permissions included:

| Permission | Used by |
|---|---|
| `storage.objects.list` | Log browser — lists available archives |
| `storage.objects.get` | Log browser — downloads an archive to parse it |
| `storage.objects.create` | Log rotation cron — uploads compressed log archives |
| `storage.objects.delete` | Only needed for a delete-style smoke test |

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

## Monitoring API

A read-only HTTP API on the openvpn-ui app that publishes live VPN telemetry
for a centralized monitoring system. Same `:8443` HTTPS listener as the UI,
under `/api/v1/metrics/`.

**Default-deny.** With `MetricsAuthToken = ""` in `app.conf` the whole
namespace returns `404 Not Found` so the surface is invisible until you opt in.
Once a token is configured, requests must present
`Authorization: Bearer <token>`. The session cookie that authenticates the UI
does **not** grant access to this namespace.

Enable it during install:

```bash
# Auto-generate a token (printed in the post-install summary):
sudo ./host/setup.sh install ... --generate-metrics-token

# Or supply your own:
sudo ./host/setup.sh install ... --metrics-token "$(openssl rand -hex 32)"
```

### Endpoints

| Endpoint                            | Returns                                                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------ |
| `GET /api/v1/metrics/summary`       | Scalar counts: `n_connected`, `n_recent_disconnects`, `n_port_forwards`, cert counts |
| `GET /api/v1/metrics/clients`       | Connected clients with CN, real IP (geo-enriched if MaxMind set), virtual IP, bytes, connected_since |
| `GET /api/v1/metrics/disconnects`   | Sessions disconnected within `?window=Nh` (default `DisconnectsWindowH`)             |
| `GET /api/v1/metrics/portforwards`  | Current NAT rules — proxied from `port-forward.sh list --format json`                |
| `GET /api/v1/metrics/certificates`  | `{active, revoked, expiring_30d, expired, by_cn: [...]}`                             |
| `GET /api/v1/metrics/prometheus`    | Same data as Prometheus text exposition (`text/plain; version=0.0.4`)                |

JSON endpoints wrap their payload as `{"generated_at": "<RFC3339>", "data": …}`
so consumers can detect cache staleness.

### Scrape example (Prometheus)

```yaml
scrape_configs:
  - job_name: openvpn
    scheme: https
    metrics_path: /api/v1/metrics/prometheus
    authorization:
      type: Bearer
      credentials: <token from setup.sh output>
    static_configs:
      - targets: ["vpn.example.com:8443"]
```

Recommend pairing with cloud security-group / firewall rules so only your
central monitor's IP can reach `:8443`. See `MetricsAuthToken`,
`MetricsCacheSeconds`, `DisconnectsWindowH`, and `MetricsHashClientNames`
in the [`conf/app.conf`](#confappconf) reference for tuning knobs.

---

## Future plans

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
