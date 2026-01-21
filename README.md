# Hetzner CX23 Provisioner

Creates a CX23 server on Hetzner Cloud, hardens it at boot via cloud-init, configures UFW, optionally copies files, and runs a startup script.

## Prereqs
- curl, jq, ssh, ssh-keygen
- A Hetzner Cloud API token in `.env`
- An SSH public key on disk (default: `~/.ssh/id_ed25519.pub`)

## Quick Start: Deploy with Docker

The easiest way to deploy an app:

```bash
# 1. Set up your API token
cp .env.example .env
# Edit .env and set HC_KEY=your-token

# 2. Deploy a directory (auto-detects docker-compose.yml)
./deploy.sh ./my-app
```

This will:
- Create an Ubuntu 24.04 server and install Docker CE
- Set up Hetzner Cloud Firewall (ports 22, 80, 443)
- Copy your directory to the server
- Run `docker compose up -d` if docker-compose.yml exists

## Quick Start: Provision Only

For more control, use provision.sh directly:

1. Copy `.env.example` to `.env` and fill in `HC_KEY`.
2. (Optional) Update defaults in `.env` (ports, server name, location, etc.).
3. Run: `./scripts/provision.sh`

## What It Does
- Creates or reuses a Hetzner SSH key by name.
- Creates a CX23 server (or configured type/image/location).
- Boots with cloud-init hardening:
  - package update/upgrade
  - installs `ufw` and `fail2ban`
  - creates a sudo user
  - disables root login and password auth
  - enables UFW with allowed ports
- Waits for SSH to be ready.
- Optionally adds a ClouDNS CNAME record for the server.
- Optionally copies files and runs a startup script.

## Configuration
All values can be set in `.env` (see `.env.example`).

Key options:
- `HC_ALLOWED_PORTS`: Comma-separated TCP ports to allow in UFW (default `22`).
- `HC_COPY_SRC`: Local path to copy to the server (optional).
- `HC_STARTUP_SCRIPT`: Local script to run on the server after copy.
- `CLOUDNS_*`: Optional ClouDNS DNS record settings (requires `CLOUDNS_AUTH_ID` and `CLOUDNS_AUTH_PASSWORD`).

## Files
- `deploy.sh`: One-command deploy with Docker CE + Cloud Firewall.
- `scripts/provision.sh`: Low-level provisioner (env-driven).
- `scripts/startup.sh`: User-editable post-provision script.
- `docs/MANUAL.md`: Full operational guide.

## Security

**Deploy script (`deploy.sh`):**
- Uses Hetzner Cloud Firewall (external, Docker can't bypass it)
- Pre-configured for ports 22, 80, 443 (configurable via `HC_DEPLOY_PORTS`)
- UFW + fail2ban for defense-in-depth
- SSH key-only auth, no root login

**Provision script (`provision.sh`):**
- UFW firewall via cloud-init
- fail2ban for SSH brute-force protection
- Non-root sudo user with SSH key auth

## Notes
- `deploy.sh` uses Ubuntu 24.04 and installs Docker CE via script (more reliable than Hetzner App images).
- `provision.sh` defaults to Ubuntu 24.04. Adjust `HC_IMAGE` if needed.
- Ports are applied to UFW at first boot via cloud-init.
- For HTTPS, use Caddy in your docker-compose.yml (see `demo/` for example).
