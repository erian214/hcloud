#!/usr/bin/env bash
set -euo pipefail

# manage.sh - Manage Hetzner Cloud servers
# Usage: manage.sh <command> [server-name|server-id]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

HC_API="https://api.hetzner.cloud/v1"

usage() {
  echo "Usage: manage.sh <command> [args...]"
  echo ""
  echo "Commands:"
  echo "  list                          List all servers"
  echo "  stop <name|id>                Stop (power off) a server"
  echo "  start <name|id>               Start (power on) a server"
  echo "  delete <name|id>              Delete a server permanently"
  echo "  ssh <name|id>                 SSH into a server"
  echo "  ip <name|id>                  Get server IP address"
  echo "  status <name|id>              Get server status"
  echo "  sync <name|id> <local-dir>    Upload/sync local dir to server"
  echo "  download <name|id> <remote> <local>  Download from server"
  echo ""
  echo "Examples:"
  echo "  manage.sh list"
  echo "  manage.sh stop demo-devlab"
  echo "  manage.sh delete 118007214"
  echo "  manage.sh ssh demo-devlab"
  echo "  manage.sh sync demo-devlab ./my-app      # Upload to ~/my-app"
  echo "  manage.sh download demo-devlab ~/app ./backup  # Download ~/app to ./backup"
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

# Get server ID from name or return ID if numeric
get_server_id() {
  local name_or_id="$1"

  # If it's a number, assume it's an ID
  if [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
    echo "$name_or_id"
    return 0
  fi

  # Otherwise, look up by name
  local server_id
  server_id=$(api_request GET "/servers?name=$name_or_id" | jq -r '.servers[0].id // empty')

  if [[ -z "$server_id" ]]; then
    echo "Error: Server not found: $name_or_id" >&2
    return 1
  fi

  echo "$server_id"
}

# Get server info
get_server_info() {
  local server_id="$1"
  api_request GET "/servers/$server_id"
}

cmd_list() {
  echo "Servers:"
  echo ""
  api_request GET "/servers" | jq -r '.servers[] | "  \(.name)\t\(.status)\t\(.public_net.ipv4.ip)\tid:\(.id)"' | column -t -s $'\t'
  echo ""
}

cmd_stop() {
  local name_or_id="$1"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  echo "Stopping server $server_id..."
  local resp
  resp=$(api_request POST "/servers/$server_id/actions/poweroff")

  local status
  status=$(jq -r '.action.status // .error.message' <<< "$resp")
  echo "Status: $status"
}

cmd_start() {
  local name_or_id="$1"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  echo "Starting server $server_id..."
  local resp
  resp=$(api_request POST "/servers/$server_id/actions/poweron")

  local status
  status=$(jq -r '.action.status // .error.message' <<< "$resp")
  echo "Status: $status"
}

cmd_delete() {
  local name_or_id="$1"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  # Get server name for confirmation
  local server_name
  server_name=$(get_server_info "$server_id" | jq -r '.server.name')

  echo "WARNING: This will permanently delete server '$server_name' (ID: $server_id)"
  read -p "Type 'yes' to confirm: " confirm

  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi

  echo "Deleting server $server_id..."
  local resp
  resp=$(api_request DELETE "/servers/$server_id")

  local status
  status=$(jq -r '.action.status // .error.message // "deleted"' <<< "$resp")
  echo "Status: $status"
}

cmd_ssh() {
  local name_or_id="$1"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  local server_ip
  server_ip=$(get_server_info "$server_id" | jq -r '.server.public_net.ipv4.ip')

  local user="${HC_USER:-ops}"
  echo "Connecting to $user@$server_ip..."
  exec ssh -o StrictHostKeyChecking=accept-new "$user@$server_ip"
}

cmd_ip() {
  local name_or_id="$1"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  get_server_info "$server_id" | jq -r '.server.public_net.ipv4.ip'
}

cmd_status() {
  local name_or_id="$1"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  get_server_info "$server_id" | jq -r '.server | "Name: \(.name)\nStatus: \(.status)\nIP: \(.public_net.ipv4.ip)\nType: \(.server_type.name)\nImage: \(.image.name)\nCreated: \(.created)"'
}

cmd_sync() {
  local name_or_id="$1"
  local local_dir="$2"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  if [[ ! -d "$local_dir" ]]; then
    echo "Error: Directory not found: $local_dir" >&2
    exit 1
  fi

  local server_ip
  server_ip=$(get_server_info "$server_id" | jq -r '.server.public_net.ipv4.ip')

  local user="${HC_USER:-ops}"
  local dir_name
  dir_name=$(basename "$local_dir")

  echo "Syncing '$local_dir' to $user@$server_ip:~/$dir_name..."

  if command -v rsync >/dev/null 2>&1; then
    rsync -avz --delete -e "ssh -o StrictHostKeyChecking=accept-new" "$local_dir/" "$user@$server_ip:~/$dir_name/"
  else
    scp -r -o StrictHostKeyChecking=accept-new "$local_dir" "$user@$server_ip:~/"
  fi

  echo "Done."
}

cmd_download() {
  local name_or_id="$1"
  local remote_path="$2"
  local local_path="$3"
  local server_id
  server_id=$(get_server_id "$name_or_id") || exit 1

  local server_ip
  server_ip=$(get_server_info "$server_id" | jq -r '.server.public_net.ipv4.ip')

  local user="${HC_USER:-ops}"

  echo "Downloading $user@$server_ip:$remote_path to $local_path..."

  if command -v rsync >/dev/null 2>&1; then
    rsync -avz -e "ssh -o StrictHostKeyChecking=accept-new" "$user@$server_ip:$remote_path" "$local_path"
  else
    scp -r -o StrictHostKeyChecking=accept-new "$user@$server_ip:$remote_path" "$local_path"
  fi

  echo "Done."
}

# Main
require_var HC_KEY

if [[ $# -lt 1 ]]; then
  usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
  list)
    cmd_list
    ;;
  stop)
    [[ $# -lt 1 ]] && usage
    cmd_stop "$1"
    ;;
  start)
    [[ $# -lt 1 ]] && usage
    cmd_start "$1"
    ;;
  delete|rm|kill)
    [[ $# -lt 1 ]] && usage
    cmd_delete "$1"
    ;;
  ssh)
    [[ $# -lt 1 ]] && usage
    cmd_ssh "$1"
    ;;
  ip)
    [[ $# -lt 1 ]] && usage
    cmd_ip "$1"
    ;;
  status|info)
    [[ $# -lt 1 ]] && usage
    cmd_status "$1"
    ;;
  sync|upload|push)
    [[ $# -lt 2 ]] && usage
    cmd_sync "$1" "$2"
    ;;
  download|pull)
    [[ $# -lt 3 ]] && usage
    cmd_download "$1" "$2" "$3"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    usage
    ;;
esac
