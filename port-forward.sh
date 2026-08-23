#!/usr/bin/env bash
# ==============================================================================
# SDV Horizon - Gateway Access & Port-Forwarding Script
#
# Defaults to standard HTTP port 80.
# Preserves user's gcloud and kubeconfig credentials across sudo elevation.
# ==============================================================================
set -e

PORT="${1:-80}"
DOMAINS="dev.horizon-sdv.com mcp.dev.horizon-sdv.com"

# Resolve calling user's home and configs
if [ -n "$SUDO_USER" ]; then
  CALLER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  export HOME="${CALLER_HOME}"
  export KUBECONFIG="${KUBECONFIG:-${CALLER_HOME}/.kube/config}"
  export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-${CALLER_HOME}/.config/gcloud}"
else
  export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
  export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-${HOME}/.config/gcloud}"
fi

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}=== SDV Horizon Access Manager ===${NC}"

# Re-run with sudo if binding to privileged port (< 1024) and not root
if [ "$PORT" -lt 1024 ] && [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Port ${PORT} is a privileged port. Elevating with sudo...${NC}"
  exec sudo \
    HOME="$HOME" \
    KUBECONFIG="$KUBECONFIG" \
    CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" \
    PATH="$PATH" \
    "$0" "$@"
fi

# Check and update /etc/hosts if necessary
MISSING_HOSTS=false
for domain in $DOMAINS; do
  if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
    MISSING_HOSTS=true
    break
  fi
done

if [ "$MISSING_HOSTS" = true ]; then
  echo -e "${YELLOW}Adding missing domain entries to /etc/hosts...${NC}"
  for domain in $DOMAINS; do
    if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
      echo -e "  Adding: 127.0.0.1 $domain"
      echo "127.0.0.1 $domain" >> /etc/hosts
    fi
  done
  echo -e "${GREEN}✓ /etc/hosts updated successfully.${NC}"
else
  echo -e "${GREEN}✓ /etc/hosts domain mappings verified (dev.horizon-sdv.com -> 127.0.0.1).${NC}"
fi

if [ "$PORT" -eq 80 ]; then
  BASE_URL="http://dev.horizon-sdv.com"
else
  BASE_URL="http://dev.horizon-sdv.com:${PORT}"
fi

echo ""
echo -e "${CYAN}${BOLD}----------------------------------------------------------------------${NC}"
echo -e "${GREEN}${BOLD}  Horizon SDV Platform is READY!${NC}"
echo -e "${CYAN}${BOLD}----------------------------------------------------------------------${NC}"
echo -e "  ${BOLD}Landing Page:${NC}       ${BASE_URL}/"
echo -e "  ${BOLD}Argo CD:${NC}            ${BASE_URL}/argocd"
echo -e "  ${BOLD}Developer Portal:${NC}   ${BASE_URL}/developer-portal"
echo -e "  ${BOLD}Argo Workflows:${NC}     ${BASE_URL}/workflows"
echo -e "  ${BOLD}Jenkins:${NC}            ${BASE_URL}/jenkins"
echo -e "  ${BOLD}Gerrit:${NC}             ${BASE_URL}/gerrit"
echo -e "  ${BOLD}Keycloak SSO:${NC}       ${BASE_URL}/auth"
echo -e "  ${BOLD}Headlamp (K8s UI):${NC}  ${BASE_URL}/headlamp"
echo -e "  ${BOLD}Grafana:${NC}            ${BASE_URL}/grafana"
echo -e "${CYAN}${BOLD}----------------------------------------------------------------------${NC}"
echo -e "  ${BOLD}CREDENTIALS (SSO & Logins):${NC}"
echo -e "  • ${BOLD}Horizon Admin (SSO User):${NC}  Username: ${GREEN}horizon-admin${NC}  |  Password: ${GREEN}HorizonDevUser2026!${NC}"
echo -e "    ${YELLOW}(Use this for Argo CD, Jenkins, Gerrit, Dev Portal, Headlamp, Grafana)${NC}"
echo -e "  • ${BOLD}Keycloak Master Admin:${NC}      Username: ${GREEN}admin${NC}          |  Password: ${GREEN}HorizonDevAdmin2026!${NC}"
echo -e "    ${YELLOW}(Use this to log into the Keycloak administration console at /auth)${NC}"
echo -e "${CYAN}${BOLD}----------------------------------------------------------------------${NC}"
echo ""
echo -e "${CYAN}Starting port-forward to GKE Gateway Tunnel on port ${PORT}...${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop.${NC}"
echo ""

# Loop to maintain connection and auto-reconnect if dropped
while true; do
  kubectl --kubeconfig="$KUBECONFIG" port-forward -n gke-gateway svc/gateway-tunnel "${PORT}:80" || true
  echo -e "${YELLOW}Port-forward disconnected. Reconnecting in 2 seconds...${NC}"
  sleep 2
done
