#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq
require_cmd ssh
require_cmd ssh-keygen

require_var HC_KEY

HC_API="https://api.hetzner.cloud/v1"

HC_SERVER_TYPE="${HC_SERVER_TYPE:-cx23}"
HC_IMAGE="${HC_IMAGE:-ubuntu-24.04}"
HC_LOCATION="${HC_LOCATION:-fsn1}"
HC_SERVER_NAME="${HC_SERVER_NAME:-cx23-$(date +%Y%m%d-%H%M%S)}"
HC_SSH_KEY_NAME="${HC_SSH_KEY_NAME:-hcloud-key}"
HC_SSH_PUBLIC_KEY="${HC_SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
HC_USER="${HC_USER:-ops}"
HC_ALLOWED_PORTS="${HC_ALLOWED_PORTS:-22}"
HC_EXTRA_PACKAGES="${HC_EXTRA_PACKAGES:-}"
HC_COPY_SRC="${HC_COPY_SRC:-}"
HC_STARTUP_SCRIPT="${HC_STARTUP_SCRIPT:-$ROOT_DIR/scripts/startup.sh}"
HC_WAIT_TIMEOUT="${HC_WAIT_TIMEOUT:-420}"
HC_FIREWALL_IDS="${HC_FIREWALL_IDS:-}"

CLOUDNS_AUTH_PASSWORD="${CLOUDNS_AUTH_PASSWORD:-}"
CLOUDNS_DOMAIN="${CLOUDNS_DOMAIN:-}"
CLOUDNS_CNAME_HOST="${CLOUDNS_CNAME_HOST:-}"
CLOUDNS_CNAME_TARGET="${CLOUDNS_CNAME_TARGET:-}"
CLOUDNS_TTL="${CLOUDNS_TTL:-3600}"

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

trim_csv() {
  local value="$1"
  value="${value// /}"
  value="${value#,}"
  value="${value%,}"
  printf '%s' "$value"
}

build_user_data() {
  local pub_key="$1"
  local user="$2"
  local allowed_ports
  local extra_packages

  allowed_ports="$(trim_csv "$3")"
  extra_packages="$(trim_csv "$4")"

  local packages=("ufw" "fail2ban")

  if [[ -n "$extra_packages" ]]; then
    IFS=',' read -ra extra_list <<< "$extra_packages"
    for pkg in "${extra_list[@]}"; do
      [[ -n "$pkg" ]] && packages+=("$pkg")
    done
  fi

  # Start YAML output
  cat <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
EOF

  # Add packages
  for pkg in "${packages[@]}"; do
    echo "  - ${pkg}"
  done

  cat <<EOF
users:
  - name: ${user}
    groups: sudo
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - ${pub_key}
disable_root: true
ssh_pwauth: false
runcmd:
  - ufw default deny incoming
  - ufw default allow outgoing
EOF

  # Add UFW port rules
  IFS=',' read -ra port_list <<< "$allowed_ports"
  for port in "${port_list[@]}"; do
    [[ -z "$port" ]] && continue
    echo "  - ufw allow ${port}/tcp"
  done

  cat <<EOF
  - ufw --force enable
  - systemctl enable --now fail2ban
EOF
}

get_ssh_key_id() {
  local name="$1"
  api_request GET "/ssh_keys" | jq -r --arg name "$name" '.ssh_keys[] | select(.name==$name) | .id' | head -n1
}

create_ssh_key() {
  local name="$1"
  local pub_key="$2"
  local payload

  payload=$(jq -n --arg name "$name" --arg key "$pub_key" '{name:$name, public_key:$key}')
  api_request POST "/ssh_keys" "$payload" | jq -r '.ssh_key.id'
}

wait_for_action() {
  local action_id="$1"
  local timeout="$2"
  local start

  start=$(date +%s)
  while true; do
    local status
    status=$(api_request GET "/actions/${action_id}" | jq -r '.action.status')
    if [[ "$status" == "success" ]]; then
      return 0
    fi
    if [[ "$status" == "error" ]]; then
      echo "Action ${action_id} failed" >&2
      return 1
    fi
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      echo "Timed out waiting for action ${action_id}" >&2
      return 1
    fi
    sleep 3
  done
}

wait_for_ssh() {
  local user="$1"
  local host="$2"
  local timeout="$3"
  local start

  start=$(date +%s)
  while true; do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${user}@${host}" "echo ready" >/dev/null 2>&1; then
      return 0
    fi
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      echo "Timed out waiting for SSH on ${host}" >&2
      return 1
    fi
    sleep 5
  done
}

add_cloudns_cname() {
  if [[ -z "$CLOUDNS_AUTH_PASSWORD" || -z "$CLOUDNS_DOMAIN" || -z "$CLOUDNS_CNAME_HOST" || -z "$CLOUDNS_CNAME_TARGET" ]]; then
    return 0
  fi

  local resp
  resp=$(curl -sS "https://api.cloudns.net/dns/add-record.json" \
    --get \
    --data-urlencode "auth-password=${CLOUDNS_AUTH_PASSWORD}" \
    --data-urlencode "domain-name=${CLOUDNS_DOMAIN}" \
    --data-urlencode "record-type=CNAME" \
    --data-urlencode "host=${CLOUDNS_CNAME_HOST}" \
    --data-urlencode "record=${CLOUDNS_CNAME_TARGET}" \
    --data-urlencode "ttl=${CLOUDNS_TTL}")

  if ! jq -e '.status == "Success"' >/dev/null 2>&1 <<< "$resp"; then
    echo "CLOUDNS CNAME creation failed: $resp" >&2
    return 1
  fi
}

if [[ ! -f "$HC_SSH_PUBLIC_KEY" ]]; then
  echo "Public key not found at $HC_SSH_PUBLIC_KEY" >&2
  echo "Generate one with: ssh-keygen -t ed25519" >&2
  exit 1
fi

SSH_KEY_ID=$(get_ssh_key_id "$HC_SSH_KEY_NAME")
if [[ -z "$SSH_KEY_ID" ]]; then
  SSH_KEY_ID=$(create_ssh_key "$HC_SSH_KEY_NAME" "$(cat "$HC_SSH_PUBLIC_KEY")")
fi

USER_DATA=$(build_user_data "$(cat "$HC_SSH_PUBLIC_KEY")" "$HC_USER" "$HC_ALLOWED_PORTS" "$HC_EXTRA_PACKAGES")

CREATE_PAYLOAD=$(jq -n \
  --arg name "$HC_SERVER_NAME" \
  --arg server_type "$HC_SERVER_TYPE" \
  --arg image "$HC_IMAGE" \
  --arg location "$HC_LOCATION" \
  --argjson ssh_keys "[${SSH_KEY_ID}]" \
  --arg user_data "$USER_DATA" \
  '{name:$name, server_type:$server_type, image:$image, location:$location, ssh_keys:$ssh_keys, user_data:$user_data}')

# Add firewalls if specified
if [[ -n "$HC_FIREWALL_IDS" ]]; then
  FIREWALL_ARRAY="["
  IFS=',' read -ra fw_ids <<< "$HC_FIREWALL_IDS"
  for i in "${!fw_ids[@]}"; do
    [[ $i -gt 0 ]] && FIREWALL_ARRAY+=","
    FIREWALL_ARRAY+="{\"firewall\":${fw_ids[$i]}}"
  done
  FIREWALL_ARRAY+="]"
  CREATE_PAYLOAD=$(jq --argjson fw "$FIREWALL_ARRAY" '. + {firewalls:$fw}' <<< "$CREATE_PAYLOAD")
fi

CREATE_RESP=$(api_request POST "/servers" "$CREATE_PAYLOAD")
SERVER_ID=$(jq -r '.server.id' <<< "$CREATE_RESP")
ACTION_ID=$(jq -r '.action.id' <<< "$CREATE_RESP")

wait_for_action "$ACTION_ID" "$HC_WAIT_TIMEOUT"

SERVER_JSON=$(api_request GET "/servers/${SERVER_ID}")
SERVER_IP=$(jq -r '.server.public_net.ipv4.ip' <<< "$SERVER_JSON")

wait_for_ssh "$HC_USER" "$SERVER_IP" "$HC_WAIT_TIMEOUT"

add_cloudns_cname

if [[ -n "$HC_COPY_SRC" ]]; then
  if [[ ! -e "$HC_COPY_SRC" ]]; then
    echo "Copy source not found: $HC_COPY_SRC" >&2
    exit 1
  fi
  if command -v rsync >/dev/null 2>&1; then
    rsync -az --delete -e "ssh -o StrictHostKeyChecking=accept-new" "$HC_COPY_SRC" "${HC_USER}@${SERVER_IP}:~/"
  else
    scp -r -o StrictHostKeyChecking=accept-new "$HC_COPY_SRC" "${HC_USER}@${SERVER_IP}:~/"
  fi
fi

if [[ -f "$HC_STARTUP_SCRIPT" ]]; then
  scp -o StrictHostKeyChecking=accept-new "$HC_STARTUP_SCRIPT" "${HC_USER}@${SERVER_IP}:/tmp/startup.sh"
  ssh -o StrictHostKeyChecking=accept-new "${HC_USER}@${SERVER_IP}" "sudo bash /tmp/startup.sh"
fi

echo "Server ready: ${HC_SERVER_NAME} (${SERVER_IP})"
