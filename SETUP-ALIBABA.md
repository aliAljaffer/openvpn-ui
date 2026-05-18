# Setup on Alibaba Cloud ECS

This guide walks through provisioning openvpn-ui on Alibaba Cloud ECS with
the **OSS** log-archive backend. It is the cloud-specific companion to the
provider-agnostic [README](README.md) — read the README's
[Configuration reference](README.md#configuration-reference) and
[Feature notes](README.md#feature-notes) for fields, flags, and behaviors not
repeated here.

## What this guide produces

A working VPN at `https://<ECS-EIP>:8443` (or `https://<your-domain>:8443`)
backed by:

- **Networking:** VPC + vSwitch + security group, ECS instance with an EIP
- **VPN:** OpenVPN configured by [angristan/openvpn-install](https://github.com/angristan/openvpn-install)
- **UI + log archive:** openvpn-ui container with `StorageProvider = oss`,
  writing daily `.log.gz` rolls to an OSS bucket via an internal VPC endpoint
- **(Optional)** Map view powered by MaxMind GeoLite2
- **(Optional)** TCP port-forward rules from the ECS to internal hosts

---

## Prerequisites

**Local machine:**
- Docker (the build runs locally and ships a `linux/amd64` image)
- `git`, `ssh`, `scp`
- [Aliyun CLI](https://www.alibabacloud.com/help/en/cli) authenticated with
  a profile that has the permissions below

**Alibaba Cloud account permissions** (minimum, scoped to the resource prefix
you choose):

| Service | Actions |
|---|---|
| VPC      | `Create/Delete/DescribeVpcs`, `*VSwitch*`, `*SecurityGroup*`, `*EIP*`, `AllocateEipAddress`, `Associate/UnassociateEipAddress` |
| ECS      | `RunInstances`, `Describe/Stop/DeleteInstances`, `Create/DescribeKeyPair`, `AuthorizeSecurityGroup` |
| OSS      | `PutBucket`, `GetBucket`, `DeleteBucket`, `PutBucketAcl`, `PutBucketPolicy` |
| RAM      | `CreateUser`, `CreatePolicy`, `AttachPolicyToUser`, `CreateAccessKey`, plus `*Delete*` counterparts for teardown |

**Region:** examples use `me-central-1` (Riyadh). Swap as needed.

**Optional add-ons:**
- [MaxMind](https://www.maxmind.com) account — enables the map view
- A domain pointed at the ECS EIP — enables HTTPS via Let's Encrypt
  (port 80 must be open during issuance only)

---

## Step 1 — Provision the infrastructure

Create these resources in your Alibaba account (console or `aliyun` CLI):

1. **VPC** (e.g. `10.99.0.0/16`)
2. **vSwitch** in your target zone (e.g. `10.99.1.0/24`)
3. **Security group** with ingress rules:

   | Port | Proto | Source       | Purpose                                    |
   |------|-------|--------------|--------------------------------------------|
   | 22   | TCP   | your-ip/32   | SSH                                        |
   | 1194 | UDP   | 0.0.0.0/0    | OpenVPN (or whichever port you choose)     |
   | 8443 | TCP   | 0.0.0.0/0    | HTTPS UI                                   |
   | 80   | TCP   | 0.0.0.0/0    | Only during Let's Encrypt issuance         |
   | *PF* | TCP   | 0.0.0.0/0    | One rule per `--port-forward <lp:ip:dp>`   |

4. **Key pair** — generate one, save the private key locally as
   `~/.ssh/openvpn-ecs-key` (`chmod 600`)
5. **ECS instance** — Ubuntu 22.04, `ecs.t6-c2m1.large` or similar, attached
   to the SG and key pair
6. **EIP** — allocate one and bind it to the ECS

---

## Step 2 — Create the OSS bucket and RAM user

The rotation cron uploads `.log.gz` files; the log browser downloads them.
Both run inside the container, so the RAM user only needs bucket-scoped
read/write access.

1. **Create the bucket** in the same region as the ECS:
   ```bash
   aliyun oss mb oss://openvpn-log-sink-<tenant>-riyadh \
     --region me-central-1 \
     --acl private
   ```

2. **Create a RAM user** (e.g. `openvpn-log-manager`) and attach a custom
   policy scoped to that bucket only:
   ```json
   {
     "Version": "1",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["oss:GetObject","oss:PutObject","oss:DeleteObject","oss:ListObjects"],
         "Resource": [
           "acs:oss:*:*:openvpn-log-sink-<tenant>-riyadh",
           "acs:oss:*:*:openvpn-log-sink-<tenant>-riyadh/*"
         ]
       }
     ]
   }
   ```

3. **Create an access key** for the RAM user. Save the `AccessKeyId` /
   `AccessKeySecret` — you'll feed them to `setup.sh init` in Step 5.

> **Endpoint to use from the ECS:** prefer the internal VPC endpoint
> `oss-me-central-1-internal.aliyuncs.com` — uploads stay inside Alibaba's
> network and avoid public egress charges.

---

## Step 3 — SSH in and install OpenVPN

```bash
ssh -i ~/.ssh/openvpn-ecs-key root@<ECS-EIP>
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

## Step 4 — Run `setup.sh init` on the ECS

```bash
sudo ./host/setup.sh init
```

When the interactive prompts ask:
- **Storage backend:** pick `oss`
- **OSS bucket:** `openvpn-log-sink-<tenant>-riyadh`
- **OSS endpoint:** `oss-me-central-1-internal.aliyuncs.com`
- **OSS AK/SK:** the RAM-user keys from Step 2
- **Port-forwards (optional):** repeatable `<listen-port>:<dest-ip>:<dest-port>`;
  match these to the SG ingress rules from Step 1
- **MaxMind (optional):** account ID + license key
- **HTTPS (optional):** your domain; open port 80 in the SG before this step

For a fully scripted install, replace the prompts with flags — see
`sudo ./host/setup.sh install --help`. The Alibaba-specific flags are
`--storage-provider oss`, `--oss-bucket`, `--oss-endpoint`,
`--oss-access-key-id`, `--oss-access-key-secret`.

---

## Step 5 — Build and deploy from your local machine

```bash
cd openvpn-ui   # local clone
./host/deploy.sh --vm-ip <ECS-EIP> --vm-ssh-key ~/.ssh/openvpn-ecs-key
```

This builds the `linux/amd64` image locally, ships it to the ECS, and brings
up the container. The VM is intentionally too small to do the Go build
itself.

---

## Step 6 — Open the UI

Browse to `https://<ECS-EIP>:8443` (or `https://<your-domain>:8443`) and log
in with the admin credentials you set in Step 4. If HTTPS is configured, close
port 80 in the SG until the next Let's Encrypt renewal window.

To enable the monitoring API, see the
[Monitoring API section](README.md#monitoring-api) — it works the same on
every provider; pass `--generate-metrics-token` to `setup.sh` to mint a token.

---

## Alibaba-specific notes

- **OSS endpoint selection** — the **public** endpoint
  (`oss-me-central-1.aliyuncs.com`) works from your laptop for one-off
  bucket inspection; the **internal** endpoint
  (`oss-me-central-1-internal.aliyuncs.com`) is what the ECS must use for
  rotation uploads. `setup.sh` defaults to the internal one when you confirm
  the bucket is in the same region.
- **`ossutil` is no longer required at runtime.** The container uses the OSS
  Go SDK for both upload and download paths; you don't need to install
  `ossutil` inside the container or mount its binary.
- **VPC source restriction (optional hardening):** add an OSS bucket policy
  that only allows the bucket-scoped RAM user from `vpc:<your-vpc-id>` source.
  Documented in the OSS console under *Bucket → Permissions → Bucket Policy*.
- **Time skew between ECS and OSS** can cause `403 RequestTimeTooSkewed`
  during uploads. Ubuntu's `systemd-timesyncd` is enabled by default — verify
  with `timedatectl status` if uploads start failing.

## Teardown

Remove resources in reverse order: container → ECS → EIP → SG → vSwitch →
VPC → OSS bucket (empty it first) → RAM user / access key. Make sure the
bucket is empty before `DeleteBucket` or the call returns `BucketNotEmpty`.
