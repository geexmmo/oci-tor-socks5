# oci-tor-socks5

Two independent ways to get a **SOCKS5 proxy**:

1. **OCI SSH SOCKS** — Terraform spins up an Always Free Oracle Cloud `VM.Standard.E2.1.Micro`;
   `ssh -D` turns it into a SOCKS5 proxy with **no software on the VM**. Includes one-command
   ephemeral-IP rotation.
2. **Local Tor** — `tor.sh` runs Tor on your machine (no VM), exposes `127.0.0.1:9050`, and can
   pin exit countries and rotate to a different network on demand.

They are unrelated and can be used separately or chained.

---

## Requirements

| For | Need |
|---|---|
| OCI proxy | `terraform`, OCI CLI configured (`~/.oci/config`), an SSH keypair, an OCI Always Free tenancy |
| Tor proxy | `tor` package (Fedora: `sudo dnf install tor`); no root needed at runtime |

---

## A. OCI SSH SOCKS proxy

### Configure

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars     # tenancy/compartment OCIDs, admin_cidr, SOCKS creds
```

Provision:

```bash
terraform init
terraform apply
terraform output -raw public_ip
```

### Use

```bash
./proxy.sh            # status + interactive menu
./proxy.sh up         # ensure instance running, start tunnel
./proxy.sh status
./proxy.sh down
./proxy.sh rotate     # new ephemeral public IP + restart tunnel
./proxy.sh ssh        # shell on the VM
```

Browser / app: **SOCKS5 `127.0.0.1:1080`** (remote DNS / `socks5h`).

No daemon is installed by default: the tunnel is plain `ssh -N -D`.
Set `enable_microsocks = true` if you need a standalone SOCKS daemon on port 1080 instead
(opened only to `admin_cidr`, credentials from `terraform.tfvars`).

### IP rotation

`./proxy.sh rotate` releases the ephemeral public IPv4 and requests a new one, then restarts
the tunnel. The instance (disk, host key, files) is untouched.

Terraform does not manage that IP object, so `terraform output` keeps the old value until:

```bash
terraform apply -refresh-only -auto-approve
```

### What Terraform creates

VCN `10.0.0.0/16`, public subnet `10.0.1.0/24`, internet gateway + route table, a security list
allowing **22/tcp only from `admin_cidr`**, and an Ubuntu 24.04 instance on an ephemeral public IP.

`terraform destroy` removes everything.

---

## B. Local Tor SOCKS proxy

```bash
./tor.sh start [any|us|de|nl|ch|us,de]   # default: last used, else any
./tor.sh status                          # exit IP + geo
./tor.sh ip
./tor.sh newnym                          # rotate to a different /24, prints old -> new
./tor.sh newnym --plain                  # plain NEWNYM (same /24 allowed)
./tor.sh clear                           # clear exit exclusions
./tor.sh stop
./tor.sh curl -s https://api.ipify.org   # curl through Tor
```

Browser: **SOCKS5 `127.0.0.1:9050`** with remote DNS.

Details:

- Uses a user-level Tor (`DataDirectory .tor/`), **not** the system `tor` service; no root needed.
- Control port `127.0.0.1:9051` with cookie auth powers `newnym`.
- `newnym` excludes the current exit's `/24` so you get a different network, not just another
  address in the same block. If a country has only one exit network, it automatically falls back
  to plain NEWNYM instead of getting stuck.
- NEWNYM is rate-limited (~1/10 s), and **existing TCP connections keep their old circuit** —
  close/reload them (or restart the browser / flush its sockets) to see the change.
- Tor geo is **country-level only**. There is no city/state selector; `{us}` is the tightest.

Measured from Houston (Nov 2026), TTFB to a global site, 3 samples:

| Exit | Median |
|---|---|
| DE | ~0.94 s |
| CH | ~0.97 s |
| NL | ~1.28 s |
| US | ~1.66 s |
| JP | ~2.50 s |
| AU | ~5.16 s |

Tor is for changing the visible IP, not for low latency. For consistent low latency use the
OCI/physical-host proxy.

---

## Files

| File | Purpose |
|---|---|
| `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf` | OCI Terraform stack |
| `cloud-init.yaml.tftpl` | optional `microsocks` install via instance metadata (`user_data`) |
| `terraform.tfvars.example` | copy to `terraform.tfvars` |
| `proxy.sh` | one entry point for the OCI proxy (up/down/rotate/status/ssh) |
| `rotate-ip.sh`, `socks.sh` | compatibility wrappers around `proxy.sh` |
| `tor.sh` | local Tor SOCKS proxy + rotation |

---

## Security / housekeeping

- `terraform.tfvars` and `terraform.tfstate` contain the SOCKS password and are **gitignored**.
  Keep them at mode `600`. `*.tfstate*`, `.terraform/`, `.tor/`, `*.log`, `*.pid` are ignored too.
- SOCKS5 username/password auth is cleartext by protocol. With `ssh -D` there is no password
  and the transport is encrypted; prefer it when it matters.
- The OCI security list allows SSH only from `admin_cidr`. Update it if your public IP changes.
- OCI Always Free notes: resources must live in the tenancy's **home region**; `E2.1.Micro`
  has a nonzero limit in only one AD per tenancy; idle instances may be stopped after 7 days.
