# openvpn-ui (AZM fork)

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
- Filters by date archive and by user CN
- Shows connect time, disconnect time, session duration, and source location
- Exports filtered results as CSV

**Automatic log archiving**
- A host cron job collects OpenVPN journal lines into a rolling master log
- A second job compresses and uploads the master log to OSS daily at 23:59 UTC,
  or earlier if the log exceeds 10 MB
- Archives are named `openvpn-logs-YYYY-MM-DD-HHmmss.log.gz` so multiple
  rotations on the same day are handled cleanly

**GeoIP enrichment**
- Audit log sessions show city and country resolved from the client source IP
- Map view shows the same for connected clients
- Powered by the MaxMind GeoLite2-City database (same DB used by the map)

**Improved map view** (`/map`)
- Clients that disconnected within the last 4 hours appear as faded markers
  alongside currently connected clients
- Clicking a faded marker shows the CN, location, disconnect time, and duration

---

## Requirements

| Requirement | Notes |
|---|---|
| OpenVPN server | Must be installed with [angristan/openvpn-install](https://github.com/angristan/openvpn-install) or equivalent. Management interface must be enabled. |
| Docker + Docker Compose | Runs openvpn-ui as a container on the same host |
| Alibaba Cloud OSS bucket | Required for log archiving and the audit log browser |
| Alibaba Cloud RAM user | Needs `oss:*` permission on the bucket (credentials stored in `/root/.ossutilconfig`) |
| ossutil | Installed on the host by the bootstrap script; used by cron jobs for uploads |
| MaxMind GeoLite2-City | Required for the map view and location column in audit logs. Free license available at maxmind.com |

---

## Configuration

### conf/app.conf

The install script writes this file on the VM. The keys relevant to this fork:

```ini
OSSLogBucket = openvpn-log-sink-your-bucket-name
OSSEndpoint  = oss-me-central-1.aliyuncs.com
GeoipDbPath  = /usr/share/GeoIP/GeoLite2-City.mmdb
```

- `OSSLogBucket` — name of the OSS bucket that holds the `.log.gz` archives.
  Leave empty to disable the audit log browser.
- `OSSEndpoint` — OSS regional endpoint. Defaults to `oss-me-central-1.aliyuncs.com`.
- `GeoipDbPath` — absolute path to the MaxMind database inside the container.
  Leave empty to disable geo lookups (map still works, just without markers).

### OSS credentials

Credentials are read by the container from `/root/.ossutilconfig`, which is
bind-mounted read-only from the host. The format is:

```ini
[Credentials]
language=EN
accessKeyID=YOUR_ACCESS_KEY_ID
accessKeySecret=YOUR_ACCESS_KEY_SECRET
endpoint=oss-me-central-1.aliyuncs.com
```

The file must be owned by root and chmod 600 on the host.

### docker-compose.yml volumes

The container expects these mounts (written by the install script):

```yaml
volumes:
  - /etc/openvpn:/etc/openvpn
  - /etc/openvpn/easy-rsa:/usr/share/easy-rsa
  - /opt/openvpn-ui/db:/opt/openvpn-ui/db
  - /opt/openvpn-ui/conf:/opt/openvpn-ui/conf
  - /opt/scripts:/opt/scripts          # shared with host cron jobs
  - /root:/root
  - /root/.ossutilconfig:/root/.ossutilconfig:ro  # OSS credentials
  - /usr/share/GeoIP:/usr/share/GeoIP:ro          # MaxMind database
```

### Log archiving cron jobs

Installed at `/etc/cron.d/openvpn-logs` on the host:

```
* * * * * root /opt/scripts/ovpn-log-collect.sh        # append new journal lines
*/5 * * * * root /opt/scripts/ovpn-log-rotate.sh       # rotate if >= 10 MB
59 23 * * * root /opt/scripts/ovpn-log-rotate.sh --eod # end-of-day rotation
```

The master log lives at `/opt/scripts/ovpn-master.log` and is readable
by the container for the live "recently disconnected" map feature.

---

## Deployment

The Docker image is built locally (not on the VM) to avoid taxing the small
VM instance, then transferred and loaded:

```bash
# After code changes:
./bootstrap-openvpn.sh rebuild --src-dir /path/to/openvpn-ui

# Full provision (new VM):
./bootstrap-openvpn.sh provision --tenant-name acme --ui-password secret
```

The `rebuild` command builds a `linux/amd64` image on your local machine,
compresses it, SCPs it to the VM, loads it with `docker load`, and restarts
the container in one step. No build tools are needed on the VM.

---

## Feature notes

**Audit log browser — no events found**

If an archive shows "no events found", check that the log was collected with
`journalctl -o short-iso`. The parser expects lines in the format:

```
2026-04-15T14:49:28+0800 hostname openvpn[pid]: context message
```

**Recently disconnected map markers**

The map reads `/opt/scripts/ovpn-master.log` (the current day's live log)
for sessions that ended within the last 4 hours. If the master log was just
rotated and is empty, no faded markers will appear until new sessions connect
and disconnect. You can restore the most recent archive into the master log
for testing:

```bash
ossutil cp oss://your-bucket/openvpn-logs-YYYY-MM-DD-HHmmss.log.gz /tmp/r.log.gz \
  --endpoint oss-me-central-1.aliyuncs.com -f
zcat /tmp/r.log.gz > /opt/scripts/ovpn-master.log
```

**OSS SDK smoke test**

A standalone test program is included at `cmd/osstest/main.go` that verifies
upload, list, download, and delete against your real bucket. It reads
credentials from `~/.openvpn-bootstrap/credentials.json` on the operator's
machine, or `/root/.ossutilconfig` inside the container:

```bash
go run ./cmd/osstest
```

---

## Building locally

```bash
# For the host architecture (development):
go build ./...

# For the VM (linux/amd64):
docker build --platform linux/amd64 -t openvpn-ui-local:latest .
```

Dependencies are managed with Go modules. The `vendor/` directory is excluded
from git — Docker recreates it from `go.mod` and `go.sum` at build time.
