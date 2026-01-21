#!/usr/bin/env bash
set -euo pipefail

# deploy.sh - Deploy a directory to Hetzner with Docker + Cloud Firewall
# Usage: deploy.sh <directory> [server-name]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

# Load environment
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Defaults
HC_DEPLOY_PORTS="${HC_DEPLOY_PORTS:-22,80,443}"
HC_FIREWALL_NAME="${HC_FIREWALL_NAME:-deploy-firewall}"
HC_API="https://api.hetzner.cloud/v1"

usage() {
  echo "Usage: deploy.sh <directory> [server-name]"
  echo ""
  echo "Deploy a directory to a new Hetzner server with Docker CE."
  echo "If docker-compose.yml is found, runs 'docker compose up -d' automatically."
  echo ""
  echo "Arguments:"
  echo "  directory    Local directory to deploy"
  echo "  server-name  Optional server name (default: deploy-YYYYMMDD-HHMMSS)"
  echo ""
  echo "Environment variables (set in .env):"
  echo "  HC_KEY            Hetzner Cloud API token (required)"
  echo "  HC_DEPLOY_PORTS   Ports to open in firewall (default: 22,80,443)"
  echo "  HC_FIREWALL_NAME  Firewall name to create/reuse (default: deploy-firewall)"
  exit 1
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Error: Missing required env var: $name" >&2
    echo "Set it in $ENV_FILE" >&2
    exit 1
  fi
}

api_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$HC_API$path" \
      -H "Authorization: Bearer $HC_KEY" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" "$HC_API$path" \
      -H "Authorization: Bearer $HC_KEY" \
      -H "Content-Type: application/json"
  fi
}

# Get firewall ID by name, empty if not found
get_firewall_id() {
  local name="$1"
  api_request GET "/firewalls" | jq -r --arg name "$name" '.firewalls[] | select(.name==$name) | .id' | head -n1
}

# Create firewall with specified ports, returns ID
create_firewall() {
  local name="$1"
  local ports="$2"
  local rules="[]"

  IFS=',' read -ra port_list <<< "$ports"
  for port in "${port_list[@]}"; do
    [[ -z "$port" ]] && continue
    rules=$(jq --arg port "$port" '. + [{
      "direction": "in",
      "protocol": "tcp",
      "port": $port,
      "source_ips": ["0.0.0.0/0", "::/0"]
    }]' <<< "$rules")
  done

  local payload
  payload=$(jq -n --arg name "$name" --argjson rules "$rules" '{name:$name, rules:$rules}')

  local resp
  resp=$(api_request POST "/firewalls" "$payload")

  local fw_id
  fw_id=$(jq -r '.firewall.id' <<< "$resp")

  if [[ -z "$fw_id" || "$fw_id" == "null" ]]; then
    echo "Error creating firewall: $resp" >&2
    exit 1
  fi

  echo "$fw_id"
}

# Detect docker-compose file in directory
detect_compose_file() {
  local dir="$1"
  local files=("docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml")

  for file in "${files[@]}"; do
    if [[ -f "$dir/$file" ]]; then
      echo "$file"
      return 0
    fi
  done

  return 1
}

# === Main ===

if [[ $# -lt 1 ]]; then
  usage
fi

DEPLOY_DIR="$1"
SERVER_NAME="${2:-deploy-$(date +%Y%m%d-%H%M%S)}"

# Validate
if [[ ! -d "$DEPLOY_DIR" ]]; then
  echo "Error: Directory not found: $DEPLOY_DIR" >&2
  exit 1
fi

require_var HC_KEY

# Get absolute path and basename
DEPLOY_DIR="$(cd "$DEPLOY_DIR" && pwd)"
DIR_BASENAME="$(basename "$DEPLOY_DIR")"

# Detect docker-compose
COMPOSE_FILE=""
if COMPOSE_FILE=$(detect_compose_file "$DEPLOY_DIR"); then
  echo "Detected: $COMPOSE_FILE"
else
  echo "No docker-compose file found - deploying files only"
fi

# Get or create firewall
echo "Setting up Hetzner Cloud Firewall: $HC_FIREWALL_NAME"
FIREWALL_ID=$(get_firewall_id "$HC_FIREWALL_NAME")

if [[ -z "$FIREWALL_ID" ]]; then
  echo "  Creating firewall with ports: $HC_DEPLOY_PORTS"
  FIREWALL_ID=$(create_firewall "$HC_FIREWALL_NAME" "$HC_DEPLOY_PORTS")
  echo "  Created firewall ID: $FIREWALL_ID"
else
  echo "  Using existing firewall ID: $FIREWALL_ID"
fi

# Generate startup script
STARTUP_SCRIPT=$(mktemp)
trap 'rm -f "$STARTUP_SCRIPT"' EXIT

cat > "$STARTUP_SCRIPT" << 'STARTUP_HEADER'
#!/usr/bin/env bash
set -euo pipefail

# Install Docker CE and Docker Compose
echo "Installing Docker CE..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# Add user to docker group for non-sudo access
STARTUP_HEADER

# Add user to docker group
cat >> "$STARTUP_SCRIPT" << STARTUP_USER
usermod -aG docker "\${SUDO_USER:-ops}"
STARTUP_USER

# Add compose commands if detected
if [[ -n "$COMPOSE_FILE" ]]; then
  cat >> "$STARTUP_SCRIPT" << STARTUP_COMPOSE

# Start Docker Compose services
DEPLOY_DIR="/home/\${SUDO_USER:-ops}/$DIR_BASENAME"
cd "\$DEPLOY_DIR"

echo "Starting Docker Compose services..."
docker compose up -d

echo ""
echo "Docker services:"
docker compose ps
STARTUP_COMPOSE
else
  cat >> "$STARTUP_SCRIPT" << 'STARTUP_NOCOMPOSE'

echo "Files deployed successfully."
echo "No docker-compose file found - skipping Docker Compose."
STARTUP_NOCOMPOSE
fi

# Set environment for provision.sh
export HC_IMAGE="${HC_DEPLOY_IMAGE:-ubuntu-24.04}"
export HC_COPY_SRC="$DEPLOY_DIR"
export HC_SERVER_NAME="$SERVER_NAME"
export HC_STARTUP_SCRIPT="$STARTUP_SCRIPT"
export HC_FIREWALL_IDS="$FIREWALL_ID"
export HC_ALLOWED_PORTS="$HC_DEPLOY_PORTS"

echo ""
echo "Deploying '$DIR_BASENAME' to server '$SERVER_NAME'..."
echo "  Image: $HC_IMAGE"
echo "  Firewall: $HC_FIREWALL_NAME (ports: $HC_DEPLOY_PORTS)"
echo ""

# Run provision
"$ROOT_DIR/scripts/provision.sh"
