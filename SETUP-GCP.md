# Setup on Google Cloud Compute Engine

This guide walks through provisioning openvpn-ui on Google Cloud Compute
Engine with the **GCS** log-archive backend. It is the cloud-specific
companion to the provider-agnostic [README](README.md) — read the README's
[Configuration reference](README.md#configuration-reference) and
[Feature notes](README.md#feature-notes) for fields, flags, and behaviors not
repeated here.

> **Status:** the openvpn-ui code (`lib/storage/gcs.go`,
> `host/scripts/setup-storage-gcs.sh`, `host/setup.sh --gcs-*` flags) is
> shipped and unit-tested. A full end-to-end pass on real GCE is pending; if
> you hit something this guide doesn't cover, please open an issue.

## What this guide produces

A working VPN at `https://<GCE-external-IP>:8443` (or
`https://<your-domain>:8443`) backed by:

- **Networking:** VPC + regional subnet + firewall rules, GCE VM with a
  static external IP
- **VPN:** OpenVPN configured by [angristan/openvpn-install](https://github.com/angristan/openvpn-install)
- **UI + log archive:** openvpn-ui container with `StorageProvider = gcs`,
  writing daily `.log.gz` rolls to a GCS bucket via a service-account JSON key
- **(Optional)** Map view powered by MaxMind GeoLite2
- **(Optional)** TCP port-forward rules from the GCE VM to internal hosts

---

## Prerequisites

**Local machine:**
- Docker (the build runs locally and ships a `linux/amd64` image)
- `git`, `ssh`, `scp`
- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install)
  authenticated against the target project:
  ```bash
  gcloud auth login
  gcloud config set project <YOUR_GCP_PROJECT_ID>
  ```

**GCP project permissions** (minimum):

| Service | Roles                                                                         |
|---------|-------------------------------------------------------------------------------|
| Compute | `roles/compute.admin` (or finer-grained: networks, subnets, firewalls, instances, addresses, images) |
| IAM     | `roles/iam.roleAdmin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountKeyAdmin` |
| Storage | `roles/storage.admin` on the project, or scoped to the bucket once it exists  |

**Region/zone:** examples use `us-central1` / `us-central1-a`. Swap as needed.

**Optional add-ons:**
- [MaxMind](https://www.maxmind.com) account — enables the map view
- A domain pointed at the GCE external IP — enables HTTPS via Let's Encrypt
  (port 80 must be open during issuance only)

---

## Step 1 — Provision the infrastructure

Create these resources in your GCP project (console or `gcloud` CLI):

1. **VPC network** (custom mode is fine):
   ```bash
   gcloud compute networks create openvpn-vpc --subnet-mode=custom
   ```

2. **Subnet** in your target region:
   ```bash
   gcloud compute networks subnets create openvpn-subnet \
     --network=openvpn-vpc --region=us-central1 --range=10.99.1.0/24
   ```

3. **Firewall rules** — one per ingress type. Restrict SSH to your IP:

   | Rule name           | Direction | Ports        | Source         |
   |---------------------|-----------|--------------|----------------|
   | `openvpn-ssh`       | ingress   | `tcp:22`     | your-ip/32     |
   | `openvpn-vpn`       | ingress   | `udp:1194`   | `0.0.0.0/0`    |
   | `openvpn-ui-https`  | ingress   | `tcp:8443`   | `0.0.0.0/0`    |
   | `openvpn-le-http`   | ingress   | `tcp:80`     | `0.0.0.0/0` *(only during LE issuance)* |
   | `openvpn-pf-<port>` | ingress   | `tcp:<lp>`   | `0.0.0.0/0`    *(one per `--port-forward`)* |

4. **Static external IP:**
   ```bash
   gcloud compute addresses create openvpn-ip --region=us-central1
   ```

5. **SSH key** — generate one locally, save as `~/.ssh/openvpn-gce-key`
   (`chmod 600`)

6. **GCE VM** — Ubuntu 22.04 LTS, `e2-small` or larger:
   ```bash
   gcloud compute instances create openvpn \
     --zone=us-central1-a \
     --machine-type=e2-small \
     --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
     --network=openvpn-vpc --subnetwork=openvpn-subnet \
     --address=$(gcloud compute addresses describe openvpn-ip \
                   --region=us-central1 --format='value(address)') \
     --metadata=enable-oslogin=FALSE,ssh-keys="ubuntu:$(cat ~/.ssh/openvpn-gce-key.pub)" \
     --boot-disk-size=20GB --boot-disk-type=pd-balanced
   ```

   > **Why `enable-oslogin=FALSE`?** With OS Login enabled, GCE ignores
   > metadata SSH keys in favor of IAM-bound logins. Disabling OS Login on
   > this VM lets `setup.sh` and `deploy.sh` use the standard
   > `ubuntu@<external-ip>` key-pair flow.

---

## Step 2 — Create the GCS bucket, role, and service account

The rotation cron uploads `.log.gz` files; the log browser downloads them.
The container reads a service-account JSON key file (read-only mount) and
talks to GCS directly via the Go SDK.

1. **Create the bucket** in the same region as the VM:
   ```bash
   gcloud storage buckets create gs://openvpn-log-sink-<tenant> \
     --project=<YOUR_GCP_PROJECT_ID> \
     --location=us-central1 \
     --uniform-bucket-level-access
   ```

2. **Create the custom IAM role** from the file shipped in this repo
   (`host/gcs-bucket-role.yaml`):
   ```bash
   gcloud iam roles create openvpnUiLogArchive \
     --project=<YOUR_GCP_PROJECT_ID> \
     --file=host/gcs-bucket-role.yaml
   ```
   The role grants `storage.objects.{create,get,list,delete}` and nothing
   else. (Using the predefined `roles/storage.objectAdmin` scoped to the
   bucket is an acceptable shortcut if you prefer not to manage a custom
   role.)

3. **Create a dedicated service account:**
   ```bash
   gcloud iam service-accounts create openvpn-ui \
     --display-name="openvpn-ui log archive"
   ```

4. **Bind the role to the SA at the bucket level** (not project-wide):
   ```bash
   gcloud storage buckets add-iam-policy-binding gs://openvpn-log-sink-<tenant> \
     --member=serviceAccount:openvpn-ui@<YOUR_GCP_PROJECT_ID>.iam.gserviceaccount.com \
     --role=projects/<YOUR_GCP_PROJECT_ID>/roles/openvpnUiLogArchive
   ```

5. **Mint a JSON key** for the SA and keep it on your local machine — it
   will be uploaded to the VM in Step 4:
   ```bash
   gcloud iam service-accounts keys create ~/openvpn-ui-gcs-sa.json \
     --iam-account=openvpn-ui@<YOUR_GCP_PROJECT_ID>.iam.gserviceaccount.com
   chmod 600 ~/openvpn-ui-gcs-sa.json
   ```

   Treat this key like a password. `setup.sh` stages it at
   `/etc/openvpn-ui/gcs-sa-key.json` on the VM (`chmod 600`) and bind-mounts
   it read-only into the container.

---

## Step 3 — SSH in and install OpenVPN

```bash
ssh -i ~/.ssh/openvpn-gce-key ubuntu@<GCE-external-IP>
sudo -i
git clone https://github.com/aliAljaffer/openvpn-ui.git
cd openvpn-ui

curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
sudo bash openvpn-install.sh install \
  --port 1194 \
  --client-cert-days 60 --server-cert-days 730 \
  --tls-sig crypt-v2 --no-client
```

Flag rationale is in the [main README](README.md#step-2--install-openvpn-on-the-vm).

---

## Step 4 — Run `setup.sh init` on the VM

Upload the SA key first:

```bash
# From your local machine
scp -i ~/.ssh/openvpn-gce-key ~/openvpn-ui-gcs-sa.json \
    ubuntu@<GCE-external-IP>:/tmp/gcs-sa.json
```

Then on the VM:

```bash
sudo ./host/setup.sh init
```

When the interactive prompts ask:
- **Storage backend:** pick `gcs`
- **GCS bucket:** `openvpn-log-sink-<tenant>`
- **GCS service-account key file:** `/tmp/gcs-sa.json` — `setup.sh` copies it
  to `/etc/openvpn-ui/gcs-sa-key.json` and sets the right permissions
- **Port-forwards (optional):** repeatable `<listen-port>:<dest-ip>:<dest-port>`;
  match these to the firewall rules from Step 1
- **MaxMind (optional):** account ID + license key
- **HTTPS (optional):** your domain; open port 80 in the firewall before this step

For a fully scripted install, replace the prompts with flags — see
`sudo ./host/setup.sh install --help`. The GCP-specific flags are
`--storage-provider gcs`, `--gcs-bucket`, `--gcs-key-file`, optionally
`--gcs-project-id`.

---

## Step 5 — Build and deploy from your local machine

```bash
cd openvpn-ui   # local clone
./host/deploy.sh --vm-ip <GCE-external-IP> --vm-ssh-key ~/.ssh/openvpn-gce-key \
                 --vm-ssh-user ubuntu
```

This builds the `linux/amd64` image locally, ships it to the GCE VM, and
brings up the container. The VM is intentionally small (`e2-small`) and not
expected to do the Go build itself.

---

## Step 6 — Open the UI

Browse to `https://<GCE-external-IP>:8443` (or `https://<your-domain>:8443`)
and log in with the admin credentials you set in Step 4. If HTTPS is
configured, close the LE-issuance firewall rule until the next renewal
window.

To enable the monitoring API, see the
[Monitoring API section](README.md#monitoring-api) — pass
`--generate-metrics-token` to `setup.sh` to mint a token.

---

## GCP-specific notes

- **OS Login vs metadata SSH keys** — leaving OS Login on is fine if you
  prefer IAM-managed access, but `host/deploy.sh` is written for the metadata
  SSH-key flow. Either disable OS Login per-instance (as in Step 1) or supply
  the IAM-managed user via `--vm-ssh-user`.
- **Same region for bucket + VM** matters for egress cost and write latency.
  Cross-region uploads work but cost more.
- **Service-account key rotation** — rotate the SA key periodically. Replace
  `/etc/openvpn-ui/gcs-sa-key.json` on the VM (same path, `chmod 600`) and
  restart the container; no app.conf change needed.
- **Avoid project-wide `roles/storage.admin`** for the runtime SA. The
  custom role from `host/gcs-bucket-role.yaml` is bucket-scoped on purpose
  — log uploads do not need bucket-management permissions.
- **Workload Identity Federation** is *not* used here because the container
  is not running on GKE/Cloud Run. If you ever migrate to GKE, swap the JSON
  key file for a workload identity binding and remove the file mount.

## Teardown

Remove resources in reverse order: container → GCE VM → static IP → firewall
rules → subnet → VPC → GCS bucket (empty it first) → service-account key /
service account → custom IAM role.
