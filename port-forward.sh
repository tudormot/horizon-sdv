#!/usr/bin/env bash
# ==============================================================================
# SDV Horizon - All-in-One Local Access & Port-Forwarding Script
#
# Forwards local ports (8080 HTTP & 8443 HTTPS) to the Horizon Gateway on GKE.
# Supports native domain routing (dev.horizon-sdv.com) and localhost.
# Blocks and keeps connections alive until interrupted (Ctrl+C).
# ==============================================================================
set -e

PROJECT_ID="cloud-bigtable-automotive"
CLUSTER_NAME="sdv-cluster"
HTTP_PORT="${1:-8080}"
HTTPS_PORT="${2:-8443}"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PIDS=()

cleanup() {
  echo ""
  echo -e "${YELLOW}Stopping all port forwarding processes...${NC}"
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  echo -e "${GREEN}Port forwards stopped cleanly.${NC}"
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

echo -e "${CYAN}${BOLD}=== SDV Horizon Access Manager ===${NC}"

# Check /etc/hosts for native domain mapping
if grep -q "dev.horizon-sdv.com" /etc/hosts 2>/dev/null; then
  echo -e "${GREEN}✓ /etc/hosts domain mapping detected: dev.horizon-sdv.com -> 127.0.0.1${NC}"
else
  echo -e "${YELLOW}Tip: For native domain support, add the following to /etc/hosts:${NC}"
  echo -e "     ${BOLD}127.0.0.1 dev.horizon-sdv.com mcp.dev.horizon-sdv.com${NC}"
fi

echo "Starting port forward on HTTP (${HTTP_PORT}) and HTTPS (${HTTPS_PORT}) -> svc/horizon-router..."

# HTTP Forward
while true; do
  kubectl port-forward -n horizon svc/horizon-router "${HTTP_PORT}:80" >/dev/null 2>&1 || true
  sleep 2
done &
PIDS+=($!)

# HTTPS Forward
while true; do
  kubectl port-forward -n horizon svc/horizon-router "${HTTPS_PORT}:443" >/dev/null 2>&1 || true
  sleep 2
done &
PIDS+=($!)

sleep 2

echo ""
echo -e "${GREEN}${BOLD}✓ SDV Horizon Gateway is ACTIVE!${NC}"
echo ""
echo -e "${CYAN}==================================================================================${NC}"
echo -e "${GREEN}${BOLD}★ NATIVE DOMAIN PORTAL (Recommended with /etc/hosts mapping):${NC}"
echo -e "${BOLD}   👉 http://dev.horizon-sdv.com:${HTTP_PORT}/${NC}"
echo -e "${BOLD}   👉 http://mcp.dev.horizon-sdv.com:${HTTP_PORT}/${NC}"
echo ""
echo -e "${GREEN}${BOLD}★ LOCALHOST PORTAL (Direct Local Access):${NC}"
echo -e "${BOLD}   👉 http://localhost:${HTTP_PORT}/${NC}"
echo -e "${CYAN}==================================================================================${NC}"
echo -e "${BOLD}Service                       Native Domain URL (with /etc/hosts)${NC}"
echo -e "${CYAN}----------------------------------------------------------------------------------${NC}"
printf "%-30s %s\n" "Horizon Landing Page"     "http://dev.horizon-sdv.com:${HTTP_PORT}/"
printf "%-30s %s\n" "Horizon Developer Portal" "http://dev.horizon-sdv.com:${HTTP_PORT}/developer-portal"
printf "%-30s %s\n" "Jenkins CI"               "http://dev.horizon-sdv.com:${HTTP_PORT}/jenkins/"
printf "%-30s %s\n" "Gerrit Code Review"       "http://dev.horizon-sdv.com:${HTTP_PORT}/gerrit/"
printf "%-30s %s\n" "Keycloak Admin Console"   "http://dev.horizon-sdv.com:${HTTP_PORT}/auth/admin/"
printf "%-30s %s\n" "Argo CD UI"               "http://dev.horizon-sdv.com:${HTTP_PORT}/argocd/"
printf "%-30s %s\n" "Grafana Monitoring"       "http://dev.horizon-sdv.com:${HTTP_PORT}/grafana/"
printf "%-30s %s\n" "Headlamp K8s UI"          "http://dev.horizon-sdv.com:${HTTP_PORT}/headlamp/"
printf "%-30s %s\n" "MTK Connect Gateway"      "http://dev.horizon-sdv.com:${HTTP_PORT}/mtk-connect"
printf "%-30s %s\n" "MCP Gateway Registry"      "http://mcp.dev.horizon-sdv.com:${HTTP_PORT}/"
echo -e "${CYAN}----------------------------------------------------------------------------------${NC}"
echo -e "${BOLD}Credentials:${NC}"
echo "  • Keycloak Admin: admin / HorizonDevAdmin2026!"
echo "  • Developer Portal / Jenkins / Gerrit SSO: horizon-admin / HorizonDevUser2026!"
echo ""
echo -e "${YELLOW}Port-forwarding is running. Press [Ctrl+C] to stop.${NC}"
echo ""

wait
