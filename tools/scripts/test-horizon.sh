#!/usr/bin/env bash
# ==============================================================================
# SDV Horizon Automated End-to-End Verification Test Suite
# Tests all subwebsites, APIs, and authentication flows programmatically.
# ==============================================================================
set -e

PORT="${1:-8080}"
TARGET_IP="127.0.0.1"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASSED_COUNT=0
FAILED_COUNT=0

log_header() {
  echo -e "\n${BOLD}${BLUE}================================================================${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}================================================================${NC}"
}

run_test() {
  local test_name="$1"
  local url="$2"
  local resolve_host="$3"
  local expected_codes="$4" # regex, e.g. "200|302|403"
  local body_regex="$5"

  echo -e -n "  Testing ${CYAN}${test_name}${NC} ... "
  
  local response_file=$(mktemp)
  local headers_file=$(mktemp)
  
  local http_code
  http_code=$(curl -s -o "$response_file" -D "$headers_file" \
    --resolve "${resolve_host}:${PORT}:${TARGET_IP}" \
    --connect-timeout 5 --max-time 10 \
    -H "Host: ${resolve_host}" \
    "$url" -w "%{http_code}" || echo "000")

  if [[ ! "$http_code" =~ ^($expected_codes)$ ]]; then
    echo -e "${RED}[FAILED]${NC} (Got HTTP ${http_code}, expected ${expected_codes})"
    echo -e "    ${YELLOW}URL:${NC} $url"
    echo -e "    ${YELLOW}Response snippet:${NC} $(head -n 2 "$response_file" | tr -d '\n')"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    rm -f "$response_file" "$headers_file"
    return 1
  fi

  if [[ -n "$body_regex" ]]; then
    if ! grep -qiE "$body_regex" "$response_file" && ! grep -qiE "$body_regex" "$headers_file"; then
      echo -e "${RED}[FAILED]${NC} (HTTP ${http_code} OK, but failed match for '${body_regex}')"
      echo -e "    ${YELLOW}Response snippet:${NC} $(head -n 2 "$response_file" | tr -d '\n')"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      rm -f "$response_file" "$headers_file"
      return 1
    fi
  fi

  echo -e "${GREEN}[PASSED]${NC} (HTTP ${http_code})"
  PASSED_COUNT=$((PASSED_COUNT + 1))
  rm -f "$response_file" "$headers_file"
  return 0
}

log_header "SDV Horizon Platform End-to-End Verification (Port ${PORT})"

# 1. Landing Page
run_test "Landing Page Root" \
  "http://dev.horizon-sdv.com:${PORT}/" \
  "dev.horizon-sdv.com" "200" "Horizon|landing|SDV"

# 2. Keycloak OIDC Discovery
run_test "Keycloak OIDC Discovery (.well-known)" \
  "http://dev.horizon-sdv.com:${PORT}/auth/realms/horizon/.well-known/openid-configuration" \
  "dev.horizon-sdv.com" "200" "authorization_endpoint|issuer"

# 3. Keycloak Direct Token Issuance (OAuth2 Direct Grants)
echo -e -n "  Testing ${CYAN}Keycloak User Authentication (admin-cli token)${NC} ... "
TOKEN_RESP=$(curl -s --resolve "dev.horizon-sdv.com:${PORT}:${TARGET_IP}" \
  -H "Host: dev.horizon-sdv.com" \
  -d "client_id=admin-cli" \
  -d "username=horizon-admin" \
  -d "password=HorizonDevUser2026!" \
  -d "grant_type=password" \
  "http://dev.horizon-sdv.com:${PORT}/auth/realms/horizon/protocol/openid-connect/token" || true)

if echo "$TOKEN_RESP" | grep -q "access_token"; then
  echo -e "${GREEN}[PASSED]${NC} (Valid JWT received)"
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  echo -e "${RED}[FAILED]${NC}"
  echo -e "    ${YELLOW}Token Response:${NC} $TOKEN_RESP"
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi

# 4. Jenkins CI
run_test "Jenkins Endpoint" \
  "http://dev.horizon-sdv.com:${PORT}/jenkins/" \
  "dev.horizon-sdv.com" "200|302|403" "Jenkins|Authentication required|redirect"

# 5. Gerrit Code Review Web UI
run_test "Gerrit Code Review Web UI" \
  "http://dev.horizon-sdv.com:${PORT}/gerrit/" \
  "dev.horizon-sdv.com" "200|302" "Gerrit|polygerrit|html"

# 6. Gerrit REST API
run_test "Gerrit REST API (Server Version)" \
  "http://dev.horizon-sdv.com:${PORT}/gerrit/config/server/version" \
  "dev.horizon-sdv.com" "200" "3\.[0-9]"

# 7. Horizon Developer Portal
run_test "Horizon Developer Portal (SPA)" \
  "http://dev.horizon-sdv.com:${PORT}/developer-portal" \
  "dev.horizon-sdv.com" "200|301|302" "Horizon|Backstage|html|<div id="

# 8. Argo CD UI & OIDC Login Initiation
run_test "Argo CD UI" \
  "http://dev.horizon-sdv.com:${PORT}/argocd/" \
  "dev.horizon-sdv.com" "200|307|308" "Argo|html"

run_test "Argo CD OIDC Login Flow" \
  "http://dev.horizon-sdv.com:${PORT}/argocd/auth/login" \
  "dev.horizon-sdv.com" "302|303" "auth/realms/horizon"

# 9. Grafana Monitoring
run_test "Grafana Dashboard UI" \
  "http://dev.horizon-sdv.com:${PORT}/grafana/" \
  "dev.horizon-sdv.com" "200|302" "Grafana|html"

# 10. Headlamp Kubernetes UI
run_test "Headlamp K8s UI" \
  "http://dev.horizon-sdv.com:${PORT}/headlamp/" \
  "dev.horizon-sdv.com" "200|302" "Headlamp|oauth2|html"

# 11. MTK Connect Gateway & SAML Login Initiation
run_test "MTK Connect Gateway" \
  "http://dev.horizon-sdv.com:${PORT}/mtk-connect" \
  "dev.horizon-sdv.com" "200|301|302" ""

run_test "MTK Connect SAML Login Flow" \
  "http://dev.horizon-sdv.com:${PORT}/mtk-connect/saml/login?RelayState=/portal" \
  "dev.horizon-sdv.com" "302" "auth/realms/horizon/protocol/saml"

# 12. MCP Gateway Registry
run_test "MCP Gateway Registry (mcp.dev.horizon-sdv.com)" \
  "http://mcp.dev.horizon-sdv.com:${PORT}/" \
  "mcp.dev.horizon-sdv.com" "200|302|404" ""

# Summary
log_header "Verification Summary"
echo -e "  Passed: ${GREEN}${PASSED_COUNT}${NC}"
echo -e "  Failed: ${RED}${FAILED_COUNT}${NC}"

if [ "$FAILED_COUNT" -eq 0 ]; then
  echo -e "\n${BOLD}${GREEN}🎉 ALL SDV HORIZON SERVICES ARE HEALTHY & VERIFIED!${NC}\n"
  exit 0
else
  echo -e "\n${BOLD}${RED}❌ Some services encountered issues.${NC}\n"
  exit 1
fi
