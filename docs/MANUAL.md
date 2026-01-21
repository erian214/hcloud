# Manual: CX23 Auto-Provisioning

## Goals
- Create the cheapest CX23 instance automatically.
- Apply baseline hardening on first boot.
- Configure UFW with a clear allowlist.
- Copy files and run a startup script.

---

## Deploy Script (deploy.sh)

The `deploy.sh` script is the recommended way to deploy applications. It wraps `provision.sh` with:
- Ubuntu 24.04 + Docker CE installed via script
- Hetzner Cloud Firewall (external firewall Docker can't bypass)
- Auto-detection and execution of docker-compose.yml

### Usage

```bash
./deploy.sh <directory> [server-name]
```

**Examples:**
```bash
./deploy.sh ./my-app                # Auto-generated server name
./deploy.sh ./my-app my-server      # Custom server name
./deploy.sh /path/to/project        # Absolute path
```

### What It Does

1. Validates the directory exists
2. Detects docker-compose.yml (or compose.yml)
3. Creates/reuses a Hetzner Cloud Firewall
4. Creates an Ubuntu 24.04 server with cloud-init hardening
5. Copies the directory to `~/directory-name` on the server
6. Installs Docker CE and docker-compose-plugin via startup script
7. Runs `docker compose up -d` if compose file exists

### Configuration

Set in `.env`:
- `HC_DEPLOY_PORTS`: Ports to open in firewall (default: `22,80,443`)
- `HC_FIREWALL_NAME`: Firewall name to create/reuse (default: `deploy-firewall`)

### Why Hetzner Cloud Firewall?

Docker manipulates iptables directly and **bypasses UFW rules**. This is a known security issue. The Hetzner Cloud Firewall operates at the network level outside the server, so Docker cannot bypass it.

UFW is still enabled for defense-in-depth, but the Cloud Firewall is the primary protection.

### Docker Access

After deployment:
- SSH: `ssh ops@<server-ip>`
- The `ops` user is in the `docker` group (no sudo needed for docker commands)
- Run `docker ps` to see running containers

---

## How It Works
1. `scripts/provision.sh` loads `.env`.
2. The script ensures an SSH key exists in Hetzner Cloud.
3. It creates the server via the Hetzner Cloud API.
4. It injects cloud-init user-data to harden the VM at boot.
5. It waits for SSH, optionally copies files, and runs the startup script.
6. If ClouDNS settings are provided, it creates a CNAME record.

## Baseline Hardening (cloud-init)
- `package_update` and `package_upgrade` enabled.
- Installs `ufw` and `fail2ban`.
- Creates a sudo user (`HC_USER`).
- Disables root login and password authentication.
- Sets UFW to deny incoming, allow outgoing.
- Allows the configured TCP ports and enables UFW.

## UFW Ports
Configure in `.env`:
- `HC_ALLOWED_PORTS=22,80,443`

Only TCP ports are opened. Keep 22 open to avoid locking yourself out.

## Startup Script
Default path: `scripts/startup.sh`
- Runs as root after SSH is available.
- Use it to install application dependencies or fetch artifacts.
- Keep it idempotent if you plan to re-run the script.

Example snippet:
```bash
#!/usr/bin/env bash
set -euo pipefail
apt-get update
apt-get install -y nginx
```

## File Copy
Set `HC_COPY_SRC` to a local path to copy into the server user's home directory.
- Uses `rsync` if available, otherwise falls back to `scp`.

## ClouDNS DNS Records (Optional)
Set these in `.env` to create DNS records via the ClouDNS API:
- `CLOUDNS_AUTH_ID` (required - your ClouDNS API user ID)
- `CLOUDNS_AUTH_PASSWORD` (required - your ClouDNS API password)
- `CLOUDNS_DOMAIN` (zone, e.g. `example.com`)
- `CLOUDNS_CNAME_HOST` (record host, e.g. `app`)
- `CLOUDNS_CNAME_TARGET` (target for CNAME, e.g. `my-app.example.net`)
- `CLOUDNS_TTL` (default `3600`, use `60` for quick updates)

Note: For A records pointing to the server IP, you'll need to create them manually or extend the script.

## Required Inputs
- `.env` with `HC_KEY`
- SSH public key file (`HC_SSH_PUBLIC_KEY`)

## Suggested Ports by Use-Case
- Web server: `22,80,443`
- SSH only: `22`
- Custom app: `22,8080` (adjust as needed)

## Troubleshooting
- If the server is created but unreachable, check your allowed ports.
- If SSH fails, verify the public key path and that your private key exists locally.
- Use Hetzner Cloud console to check the cloud-init logs if hardening fails.
