#!/usr/bin/env bash

# Copyright (c) 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:
# Opens a local tunnel to a Horizon SDV deployment that uses internal ingress
# (sdv_gateway_internal = true). Such a deployment lives behind a regional
# internal Application Load Balancer whose VIP is only routable inside the VPC.
#
# The script maps the platform hostnames to localhost in /etc/hosts and forwards
# a local port to the in-cluster relay (sdv_gateway_dev_access = true), which in
# turn reaches the Gateway VIP:
#
#   browser -> localhost:PORT -> relay Pod -> Gateway VIP -> platform
#
# It never stores or prints credentials; see --help for how to read them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../../terraform/env/terraform.tfvars"
RELAY_NAMESPACE="gke-gateway"
RELAY_SERVICE="svc/gateway-dev-access"
HOSTS_MARKER="# horizon-sdv dev-access"

PORT=80
DOMAIN=""
ACTION="forward"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
  cat <<EOF

Access a Horizon SDV deployment that uses internal ingress.

Usage: ./dev-access.sh [OPTIONS]

Options:
  -p, --port PORT     Local port to listen on (default: 80).
                      Port 80 is the default because the platform URLs registered
                      in Keycloak have no port; using another port breaks SSO
                      redirects. Binding to a port below 1024 needs sudo.
  -d, --domain NAME   Platform domain (default: read from terraform.tfvars).
  -u, --undo          Remove the /etc/hosts entries added by this script and exit.
  -h, --help          This message.

Credentials are not handled by this script. Read them from Secret Manager:
  gcloud secrets versions access latest --secret=keycloak-horizon-admin-password-b64 | base64 -d
  gcloud secrets versions access latest --secret=keycloak-admin-password-b64 | base64 -d

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)   PORT="${2:?--port needs a value}"; shift 2 ;;
    -d|--domain) DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    -u|--undo)   ACTION="undo"; shift ;;
    -h|--help)   usage ;;
    *) log_err "Unknown option: $1"; usage ;;
  esac
done

# Derive the platform domain from the deployment configuration, so the script
# works for any environment without being edited.
if [[ -z "$DOMAIN" ]]; then
  if [[ ! -f "$TFVARS" ]]; then
    log_err "terraform.tfvars not found at ${TFVARS}; pass --domain explicitly."
    exit 1
  fi
  ENV_NAME=$(awk -F'"' '/^[[:space:]]*sdv_env_name[[:space:]]*=/ {print $2}' "$TFVARS")
  ROOT_DOMAIN=$(awk -F'"' '/^[[:space:]]*sdv_root_domain[[:space:]]*=/ {print $2}' "$TFVARS")
  if [[ -z "$ENV_NAME" || -z "$ROOT_DOMAIN" ]]; then
    log_err "Could not read sdv_env_name / sdv_root_domain from ${TFVARS}; pass --domain."
    exit 1
  fi
  DOMAIN="${ENV_NAME}.${ROOT_DOMAIN}"
fi

HOSTNAMES=("${DOMAIN}" "mcp.${DOMAIN}")

# Exact-match lookup: a substring match would consider "dev.example.com" present
# because of an existing "mcp.dev.example.com" entry.
host_entry_present() {
  local escaped="${1//./\\.}"
  grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${escaped}([[:space:]]|$)" /etc/hosts 2>/dev/null
}

remove_host_entries() {
  if ! grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    log_info "No ${HOSTS_MARKER} entries in /etc/hosts."
    return 0
  fi
  local sudo_cmd=""
  [[ $EUID -ne 0 ]] && sudo_cmd="sudo"
  $sudo_cmd sed -i "/${HOSTS_MARKER}\$/d" /etc/hosts
  log_info "Removed ${HOSTS_MARKER} entries from /etc/hosts."
}

add_host_entries() {
  local missing=()
  for host in "${HOSTNAMES[@]}"; do
    host_entry_present "$host" || missing+=("$host")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "/etc/hosts already maps ${HOSTNAMES[*]} to 127.0.0.1."
    return 0
  fi
  log_warn "Adding to /etc/hosts (sudo): ${missing[*]}"
  local sudo_cmd=""
  [[ $EUID -ne 0 ]] && sudo_cmd="sudo"
  for host in "${missing[@]}"; do
    echo "127.0.0.1 ${host} ${HOSTS_MARKER}" | $sudo_cmd tee -a /etc/hosts >/dev/null
  done
  log_info "Undo with: $0 --undo"
}

if [[ "$ACTION" == "undo" ]]; then
  remove_host_entries
  exit 0
fi

command -v kubectl >/dev/null || { log_err "kubectl not found."; exit 1; }

if ! kubectl get "$RELAY_SERVICE" -n "$RELAY_NAMESPACE" >/dev/null 2>&1; then
  log_err "${RELAY_SERVICE} not found in namespace ${RELAY_NAMESPACE}."
  log_err "Set sdv_gateway_dev_access = true in terraform.tfvars and re-run deploy.sh."
  exit 1
fi

add_host_entries

BASE_URL="http://${DOMAIN}"
[[ "$PORT" != "80" ]] && BASE_URL="http://${DOMAIN}:${PORT}"

echo ""
echo -e "${BOLD}Horizon SDV is reachable at:${NC}"
echo -e "  Landing page      ${BASE_URL}/"
echo -e "  Developer Portal  ${BASE_URL}/developer-portal"
echo -e "  Argo Workflows    ${BASE_URL}/workflows"
echo -e "  Argo CD           ${BASE_URL}/argocd"
echo -e "  Jenkins           ${BASE_URL}/jenkins"
echo -e "  Gerrit            ${BASE_URL}/gerrit"
echo -e "  Keycloak          ${BASE_URL}/auth"
echo -e "  Headlamp          ${BASE_URL}/headlamp"
echo -e "  Grafana           ${BASE_URL}/grafana"
echo ""
echo -e "Credentials: ${BOLD}gcloud secrets versions access latest --secret=keycloak-horizon-admin-password-b64 | base64 -d${NC}"
echo ""

if [[ "$PORT" -lt 1024 && $EUID -ne 0 ]]; then
  log_warn "Port ${PORT} is privileged; re-running the forwarder under sudo."
  exec sudo --preserve-env=HOME,KUBECONFIG,CLOUDSDK_CONFIG,PATH \
    KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" \
    kubectl port-forward -n "$RELAY_NAMESPACE" "$RELAY_SERVICE" "${PORT}:80"
fi

log_info "Forwarding localhost:${PORT} -> ${RELAY_SERVICE} (Ctrl+C to stop)."
exec kubectl port-forward -n "$RELAY_NAMESPACE" "$RELAY_SERVICE" "${PORT}:80"
