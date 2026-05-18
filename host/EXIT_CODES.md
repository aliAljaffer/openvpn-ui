# Exit Code Map

Every non-zero exit from a `host/` or `bootstrap/` shell script now uses a
unique code so the source of a failure can be identified from the exit status
alone. Repeated validations of the same *kind* (e.g. all `--foo requires a
value` checks within one script) share a single code — the script's error
message tells you which flag was missing.

## How to read this map

1. Catch the exit code in the caller: `script.sh; rc=$?`
2. Find the code below — the row tells you which script and which failure
   kind triggered it.
3. The script also writes a human-readable message to stderr. The code points
   you at the *location*; the message describes the *value* (which flag, which
   resource, etc.).

## Reserved codes

| Code        | Meaning                                                         |
|-------------|-----------------------------------------------------------------|
| 0           | Success                                                         |
| 1           | Generic failure (any unclassified `err` / `exit 1` fallback)    |
| 2           | Reserved (bash: misuse of builtin)                              |
| 126         | Reserved (bash: command found but not executable)               |
| 127         | Reserved (bash: command not found)                              |
| 130         | Reserved (SIGINT — script killed by Ctrl+C)                     |
| 255         | Reserved (bash: exit out of range)                              |

## Range assignments

| Range     | Script                                       |
|-----------|----------------------------------------------|
| 10–19     | `host/deploy.sh`                             |
| 20–44     | `host/setup.sh`                              |
| 45–49     | `host/scripts/genclient.sh`                  |
| 56–57     | `host/scripts/ovpn-log-rotate.sh`            |
| 60–69     | `host/scripts/port-forward.sh`               |
| 75        | `host/scripts/remove.sh`                     |
| 78        | `host/scripts/renew.sh`                      |
| 81        | `host/scripts/restart.sh`                    |
| 84–85     | `host/scripts/revoke.sh`                     |
| 87–89     | `host/scripts/rmcert.sh`                     |
| 90–92     | `host/scripts/setup-storage-gcs.sh`          |
| 93–94     | `host/scripts/setup-storage-oss.sh`          |
| 96–98     | `host/scripts/setup-storage-s3.sh`           |
| 100–102   | `bootstrap/bootstrap-openvpn.sh`             |
| 103–118   | `bootstrap/bootstrap-common.sh`              |
| 123–150   | `bootstrap/bootstrap-aws.sh`                 |
| 153–171   | `bootstrap/bootstrap-gcp.sh`                 |
| 184–215   | `bootstrap/bootstrap-alibaba.sh`             |
| 219–252   | `bootstrap/openvpn-manage.sh`                |

---

## host/deploy.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 10   | Usage shown (`-h`, `--help`, or no args)                           |
| 11   | Unknown option                                                     |
| 12   | `--vm-ip` is required                                              |
| 13   | `--src-dir` path not found                                         |
| 14   | Docker not installed on local machine                              |
| 15   | `--skip-build` used but no prior `openvpn-ui-local:latest` image   |

## host/setup.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 20   | Usage shown (`-h`, `--help`, or no args)                           |
| 21   | Unknown top-level command                                          |
| 22   | Not running as root                                                |
| 23   | OpenVPN `server.conf` not found (angristan installer not run)      |
| 24   | `scripts/` directory missing next to setup.sh                      |
| 25   | Docker required but user declined auto-install                     |
| 26   | Unknown `install` flag                                             |
| 27   | `--port-forward` missing value                                     |
| 28   | Invalid `--port-forward` spec format (expected `lp:ip:dp`)         |
| 29   | `--admin-password` required for non-interactive install            |
| 30   | Unknown `--storage-provider` value                                 |
| 31   | OSS storage flags incomplete                                       |
| 32   | S3 storage flags incomplete                                        |
| 33   | GCS storage flags incomplete                                       |
| 34   | `--gcs-key-file` path not found                                    |

## host/scripts/genclient.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 45   | Client name positional arg missing                                 |
| 46   | Client `.ovpn` already exists                                      |
| 47   | `client-template-clean.txt` not found (setup.sh not run)           |

## host/scripts/ovpn-log-rotate.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 56   | Unknown `StorageProvider` in `app.conf`                            |
| 57   | Archive upload/store step failed — master log NOT truncated        |

## host/scripts/port-forward.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 60   | Not running as root                                                |
| 61   | `net.ipv4.ip_forward` not enabled on host                          |
| 62   | Invalid listen-port (must be 1–65535)                              |
| 63   | Invalid dest-ip (must be dotted IPv4)                              |
| 64   | Invalid dest-port (must be 1–65535)                                |
| 65   | listen-port already forwards to a different destination            |
| 66   | Unknown `--format` value (only `json` accepted)                    |
| 67   | Unknown flag on `list` subcommand                                  |
| 68   | Unknown top-level command (not `add`/`list`/`remove`)              |
| 69   | Usage shown (no args or wrong arg count for subcommand)            |

## host/scripts/remove.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 75   | Unknown action argument                                            |

## host/scripts/renew.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 78   | Client name positional arg missing                                 |

## host/scripts/restart.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 81   | Unknown action argument                                            |

## host/scripts/revoke.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 84   | Client name positional arg missing                                 |
| 85   | Cert serial positional arg missing                                 |

## host/scripts/rmcert.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 87   | Client name positional arg missing                                 |
| 88   | Cert serial positional arg missing                                 |
| 89   | Cert is still valid — revoke it before removing                    |

## host/scripts/setup-storage-gcs.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 90   | Not running as root                                                |
| 91   | Wrong argument count (expected `<src-key.json> <dest-key-path>`)   |
| 92   | Source service-account key file not found                          |

## host/scripts/setup-storage-oss.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 93   | Not running as root                                                |
| 94   | Wrong argument count (expected key-id, secret, endpoint)           |

## host/scripts/setup-storage-s3.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 96   | Not running as root                                                |
| 97   | Wrong argument count (expected key-id, secret, region)             |
| 98   | Unsupported CPU architecture for AWS CLI                           |

---

## bootstrap/bootstrap-openvpn.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 100  | `--provider` requires a value                                      |
| 101  | Unknown `--provider` value (must be alibaba/aws/gcp)               |
| 102  | Target provider script not found or not executable                 |

## bootstrap/bootstrap-common.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 103  | Missing required positional args on `install`                      |
| 104  | `sshpass` not installed on caller machine                          |
| 105  | SSH connection timeout waiting for VM                              |
| 106  | `git clone` of openvpn-ui failed                                   |
| 107  | `--src-dir` is not a valid openvpn-ui checkout                     |
| 108  | Missing value for some `--flag` (message names the flag)           |
| 109  | SSH credentials not provided (need key or password)                |
| 110  | Both SSH key AND password provided (must pick one)                 |
| 111  | SSH key file not found                                             |
| 112  | UI password not provided                                           |
| 113  | Required command missing in PATH (`ssh`, `scp`, `git`, etc.)       |
| 114  | Missing required positional args on `rebuild`                      |
| 115  | Unknown top-level command / usage shown                            |
| 116  | Unknown flag on `install` subcommand                               |
| 117  | Unknown flag on `rebuild` subcommand                               |
| 118  | Invalid `--port-forward` spec format                               |

## bootstrap/bootstrap-aws.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 123  | Config file not found                                              |
| 124  | `jq` not installed                                                 |
| 125  | Required command missing in PATH                                   |
| 128  | AWS credentials invalid or missing                                 |
| 129  | VPC creation failed                                                |
| 131  | Subnet creation failed                                             |
| 132  | Internet Gateway creation failed                                   |
| 133  | Route Table creation failed                                        |
| 134  | Security Group creation failed                                     |
| 135  | No Ubuntu AMI found in region                                      |
| 136  | EC2 instance creation failed                                       |
| 137  | EIP allocation failed                                              |
| 138  | No public IP after EIP association                                 |
| 139  | `bootstrap-common.sh` not found or not executable                  |
| 140  | S3 storage flags incomplete                                        |
| 141  | Unsupported `--storage-provider` for AWS (use local or s3)         |
| 142  | EC2 instance not found (destroy/rebuild lookup)                    |
| 143  | Instance has no public IP (destroy/rebuild lookup)                 |
| 144  | Missing value for some `--flag`                                    |
| 145  | Invalid `--port-forward` spec format                               |
| 146  | UI password/confirm mismatch                                       |
| 147  | Cannot determine public IP (api.ipify / ifconfig.me failed)        |
| 148  | Unknown option for `destroy` subcommand                            |
| 149  | Unknown option for `rebuild` subcommand                            |
| 150  | Unknown option for `provision` subcommand / usage shown            |

## bootstrap/bootstrap-gcp.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 153  | Config file not found                                              |
| 154  | `jq` not installed                                                 |
| 155  | Required command missing in PATH                                   |
| 156  | GCP project not set / cannot resolve                               |
| 157  | gcloud authentication failed                                       |
| 158  | `bootstrap-common.sh` not found or not executable                  |
| 159  | GCS storage flags incomplete                                       |
| 160  | GCS key file not found                                             |
| 161  | Unsupported `--storage-provider` for GCP (use local or gcs)        |
| 162  | Cannot determine public IP                                         |
| 163  | Could not determine VM public IP after provisioning                |
| 164  | Instance not found (destroy/rebuild lookup)                        |
| 165  | Instance has no public IP (destroy/rebuild lookup)                 |
| 166  | Missing value for some `--flag`                                    |
| 167  | Invalid `--port-forward` spec format                               |
| 168  | UI password/confirm mismatch                                       |
| 169  | Unknown options remaining on `destroy`                             |
| 170  | Unknown option for `rebuild` subcommand                            |
| 171  | Unknown option for `provision` subcommand / usage shown            |

## bootstrap/bootstrap-alibaba.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 184  | Config file not found                                              |
| 185  | `jq` not installed                                                 |
| 186  | Required command missing in PATH                                   |
| 187  | No credentials (run `init` first)                                  |
| 188  | Credentials file malformed                                         |
| 189  | Cannot determine public IP                                         |
| 190  | `init` missing `--access-key`/`--access-secret`                    |
| 192  | Unknown option for `init` subcommand                               |
| 193  | OSS bucket name missing                                            |
| 194  | OSS bucket creation failed                                         |
| 195  | RAM user creation failed                                           |
| 196  | RAM access key creation failed                                     |
| 197  | Failed to parse access key response                                |
| 198  | Failed to apply OSS bucket policy (or fetch Account ID for it)     |
| 199  | RAM policy creation failed                                         |
| 200  | RAM policy attachment failed                                       |
| 201  | VPC creation failed                                                |
| 202  | No zone in region supports requested instance type                 |
| 203  | vSwitch creation failed                                            |
| 204  | Security Group creation failed                                     |
| 205  | No Ubuntu image found                                              |
| 206  | ECS instance creation failed                                       |
| 207  | Instance running-state wait timeout                                |
| 208  | Instance deleted-state wait timeout                                |
| 209  | Missing value for some `--flag`                                    |
| 210  | Invalid `--port-forward` spec format                               |
| 211  | UI password/confirm mismatch                                       |
| 212  | `bootstrap-common.sh` not found or not executable                  |
| 213  | Unknown option for `provision` subcommand / usage shown            |
| 214  | Unknown option for `rebuild` subcommand                            |

> Code **191** ("unsupported architecture") and **215** ("unknown `destroy`
> option") are reserved in this range but have no corresponding call site
> today — the script lacks an arch check and `destroy` ignores extra args.

## bootstrap/openvpn-manage.sh

| Code | Meaning                                                            |
|------|--------------------------------------------------------------------|
| 219  | Config file not found                                              |
| 220  | `jq` not installed                                                 |
| 221  | Required command missing in PATH (`aliyun`, `ssh`, `scp`, etc.)    |
| 222  | No credentials (run `init` first)                                  |
| 223  | Credentials file malformed                                         |
| 224  | Cannot determine public IP                                         |
| 225  | VPC not found                                                      |
| 226  | Security group not found                                           |
| 227  | ECS instance not found                                             |
| 228  | Instance not in running state                                      |
| 229  | No public IP on instance                                           |
| 230  | Unable to SSH / connect to VPN                                     |
| 231  | SSH key file not found                                             |
| 233  | Client name required (positional arg missing)                      |
| 235  | Client not found (renew subcommand)                                |
| 236  | Client is revoked — cannot renew                                   |
| 237  | Missing value for some `--flag`                                    |
| 239  | Unknown global option                                              |
| 240  | Unknown option for `init` subcommand                               |
| 241  | Unknown option for `add` subcommand                                |
| 242  | Unknown option for `revoke` subcommand                             |
| 243  | Unknown option for `renew` subcommand                              |
| 244  | Unknown option for `list` subcommand                               |
| 245  | Unknown option for `status` subcommand                             |
| 246  | Unknown option for `check-ssh` subcommand                          |
| 247  | Port-forward missing arguments                                     |
| 248  | Port-forward `add` wrong arg count                                 |
| 249  | Port-forward `list` wrong arg count                                |
| 250  | Port-forward `remove` wrong arg count                              |
| 251  | Unknown port-forward subcommand                                    |
| 252  | Usage shown / unknown top-level command / `TODO`-classified site   |

> Codes **232**, **234**, **238** are reserved in this range but have no
> matching call site today (the script handles those conditions differently —
> e.g. revoke treats "client not found" as a no-op success). Four sites use
> **252** with a `# TODO: classify exit code` comment — they're real failure
> modes (Aliyun SG-rule API errors, `init` missing required flags, etc.) that
> didn't fit any existing kind in the table.

---

## Maintenance

When you add a new failure check:

1. Pick the next free code inside the script's range (see "Range assignments"
   above).
2. Call `err <code> "message"` (or `exit <code>` for scripts without an
   `err()` helper).
3. Add a row to the script's table here.

If a script's range is exhausted, extend it into the next unused block — but
update the "Range assignments" table at the top so future maintainers can
still locate codes at a glance.
