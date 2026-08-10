#!/usr/bin/env bash
# ==============================================================================
# SDV Horizon - Local Development & Post-Deployment Setup Script
# ==============================================================================
# This script configures an SDV Horizon deployment for seamless local development:
# 1. Deploys the unified in-cluster reverse proxy (horizon-router) in 'horizon'.
# 2. Configures Keycloak realms:
#    - Disables SSL enforcement (sslRequired=NONE) for HTTP localhost.
#    - Relaxes development password policies.
#    - Populates user profile fields and sets permanent developer credentials.
#    - Assigns developer users to 'administrators' and 'developers' groups.
#    - Configures OIDC Group Membership mapper on the Jenkins client.
#    - Adds localhost:8080 redirect URIs and web origins to all Keycloak clients.
# 3. Configures Jenkins CI:
#    - Sets in-cluster OIDC discovery endpoint.
#    - Configures Role-Based Authorization Strategy with administrator role mappings.
#    - Restarts Jenkins and verifies readiness.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Formatting
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_step() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

# ------------------------------------------------------------------------------
# 1. Deploy horizon-router
# ------------------------------------------------------------------------------
log_step "1. Deploying horizon-router (Unified Local Proxy)"
kubectl apply -f "${SCRIPT_DIR}/horizon-router.yaml"
kubectl rollout status deployment/horizon-router -n horizon --timeout=60s
log_info "horizon-router is deployed and running."

# ------------------------------------------------------------------------------
# 2. Configure Keycloak Realms, Users & OIDC Mappings
# ------------------------------------------------------------------------------
log_step "2. Configuring Keycloak Realms and Authentication"

# Authenticate kcadm CLI as master admin
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user admin \
  --password HorizonDevAdmin2026!

# Disable SSL requirement for local dev on master and horizon realms
log_info "Disabling SSL enforcement for HTTP localhost..."
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh update realms/horizon -s sslRequired=NONE

# Relax password policy
log_info "Updating password policy for local development..."
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh update realms/horizon -s 'passwordPolicy="length(8) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1)"'

# Ensure Groups exist
log_info "Verifying groups in horizon realm..."
ADMIN_GROUP_ID=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh get groups -r horizon --query name=administrators --fields id --format csv --noquotes 2>/dev/null || true)
if [ -z "${ADMIN_GROUP_ID}" ]; then
  ADMIN_GROUP_ID=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh create groups -r horizon -s name=administrators -i)
fi

DEV_GROUP_ID=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh get groups -r horizon --query name=developers --fields id --format csv --noquotes 2>/dev/null || true)
if [ -z "${DEV_GROUP_ID}" ]; then
  DEV_GROUP_ID=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh create groups -r horizon -s name=developers -i)
fi

# Create Realm Roles (administrators, developers, viewers)
log_info "Creating Keycloak realm roles for Jenkins authorization..."
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh create roles -r horizon -s name=administrators -s description="Platform Administrators" 2>/dev/null || true
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh create roles -r horizon -s name=developers -s description="Platform Developers" 2>/dev/null || true
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh create roles -r horizon -s name=viewers -s description="Platform Viewers" 2>/dev/null || true

# Configure horizon-admin user profile & credentials
log_info "Configuring horizon-admin user profile and permanent credentials..."
HORIZON_ADMIN_ID=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh get users -r horizon --query username=horizon-admin --fields id --format csv --noquotes 2>/dev/null || true)
if [ -n "${HORIZON_ADMIN_ID}" ]; then
  kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh update users/${HORIZON_ADMIN_ID} -r horizon \
    -s 'firstName=Horizon' \
    -s 'lastName=Admin' \
    -s 'email=horizon-admin@horizon.local' \
    -s 'emailVerified=true' \
    -s 'requiredActions=[]'
  kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh set-password -r horizon --username horizon-admin --new-password HorizonDevUser2026!
  
  # Assign to groups and realm roles
  kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh update users/${HORIZON_ADMIN_ID}/groups/${ADMIN_GROUP_ID} -r horizon || true
  kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh update users/${HORIZON_ADMIN_ID}/groups/${DEV_GROUP_ID} -r horizon || true
  kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh add-roles -r horizon --uusername horizon-admin --rolename administrators --rolename developers 2>/dev/null || true
fi

# Configure OIDC Group Membership Mapper on Jenkins Client
log_info "Configuring OIDC Group Membership claim mapper on Jenkins client..."
JENKINS_CLIENT_ID=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh get clients -r horizon --query clientId=jenkins --fields id --format csv --noquotes 2>/dev/null || true)
if [ -n "${JENKINS_CLIENT_ID}" ]; then
  EXISTING_MAPPER=$(kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh get clients/${JENKINS_CLIENT_ID}/protocol-mappers/models -r horizon | grep -i '"name" : "groups"' || true)
  if [ -z "${EXISTING_MAPPER}" ]; then
    kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- /opt/keycloak/bin/kcadm.sh create clients/${JENKINS_CLIENT_ID}/protocol-mappers/models -r horizon \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s consentRequired=false \
      -s 'config={"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}'
  fi
fi

# Add localhost and domain redirect URIs to Keycloak Clients
log_info "Updating Keycloak clients redirect URIs..."
kubectl exec -n keycloak keycloak-keycloakx-0 -c keycloak -- bash -c '
for client in jenkins gerrit argocd grafana-oauth oauth2-headlamp horizon-dev-portal horizon-api argo-workflows-oauth; do
  id=$(/opt/keycloak/bin/kcadm.sh get clients -r horizon --query clientId=$client --fields id --format csv --noquotes 2>/dev/null || true)
  if [ -n "$id" ]; then
    /opt/keycloak/bin/kcadm.sh update clients/$id -r horizon \
      -s "redirectUris=[\"https://dev.horizon-sdv.com/*\",\"http://dev.horizon-sdv.com:8080/*\",\"http://localhost:8080/*\",\"http://127.0.0.1:8080/*\",\"http://localhost:3000/*\",\"http://localhost:8085/*\",\"http://localhost:8086/*\",\"http://localhost:8087/*\",\"http://localhost:8088/*\",\"http://localhost:8089/*\"]" \
      -s "webOrigins=[\"+\",\"http://dev.horizon-sdv.com:8080\",\"http://localhost:8080\",\"http://127.0.0.1:8080\",\"https://dev.horizon-sdv.com\"]" 2>/dev/null || true
  fi
done

# SAML client for mtk-connect
mtk_id=$(/opt/keycloak/bin/kcadm.sh get clients -r horizon --query clientId=mtk-connect --fields id --format csv --noquotes 2>/dev/null || true)
if [ -n "$mtk_id" ]; then
  /opt/keycloak/bin/kcadm.sh update clients/$mtk_id -r horizon \
    -s "adminUrl=http://dev.horizon-sdv.com:8080/mtk-connect/saml/consume" \
    -s "baseUrl=/mtk-connect/saml/consume" \
    -s "redirectUris=[\"https://dev.horizon-sdv.com/mtk-connect/saml/consume\",\"http://dev.horizon-sdv.com:8080/mtk-connect/saml/consume\",\"http://localhost:8080/mtk-connect/saml/consume\",\"http://dev.horizon-sdv.com:8080/*\"]" \
    -s "attributes.\"saml_assertion_consumer_url_post\"=http://dev.horizon-sdv.com:8080/mtk-connect/saml/consume" \
    -s "attributes.\"saml_assertion_consumer_url_redirect\"=http://dev.horizon-sdv.com:8080/mtk-connect/saml/consume" 2>/dev/null || true
fi
'

# ------------------------------------------------------------------------------
# 3. Configure Workloads (Jenkins, ArgoCD, MTK Connect)
# ------------------------------------------------------------------------------
log_step "3. Configuring In-Cluster Workload Integrations"

ROUTER_IP=$(kubectl get svc -n horizon horizon-router -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

# Jenkins
log_info "Configuring Jenkins CI OIDC Discovery & Role Authorization..."
JENKINS_KEYCLOAK_JSON=$(cat << 'EOF'
{
  "realm": "horizon",
  "auth-server-url": "http://dev.horizon-sdv.com:8080/auth",
  "ssl-required": "none",
  "resource": "jenkins",
  "credentials": {
    "secret": "zJ9bLXGGUsKrxM5HcNNP0E2WrmZyeKTB"
  },
  "confidential-port": 0
}
EOF
)
B64_JSON=$(echo -n "${JENKINS_KEYCLOAK_JSON}" | base64 -w 0)
kubectl patch secret jenkins-keycloak -n jenkins --type merge -p "{\"data\":{\"keycloakJson\":\"${B64_JSON}\"}}"

if [ -n "${ROUTER_IP}" ]; then
  kubectl patch statefulset jenkins -n jenkins --type=json -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${ROUTER_IP}\", \"hostnames\": [\"dev.horizon-sdv.com\", \"mcp.dev.horizon-sdv.com\"]}]}]" 2>/dev/null || true
fi

if kubectl exec -n jenkins jenkins-0 -c jenkins -- test -f /var/jenkins_home/config.xml 2>/dev/null; then
  cat << 'XML' | kubectl exec -i -n jenkins jenkins-0 -c jenkins -- bash -c '
cat > /tmp/new_auth_strategy.xml
sed -i "/<authorizationStrategy/,/<\/authorizationStrategy>/ {
  /<authorizationStrategy/ {
    r /tmp/new_auth_strategy.xml
  }
  d
}" /var/jenkins_home/config.xml
' || true
  <authorizationStrategy class="com.michelin.cio.hudson.plugins.rolestrategy.RoleBasedAuthorizationStrategy">
    <permissionTemplates>
      <template name="administrators">
        <permissions>
          <permission>hudson.model.View.Delete</permission>
          <permission>hudson.model.Item.Create</permission>
          <permission>hudson.model.Run.Delete</permission>
          <permission>hudson.model.Item.Workspace</permission>
          <permission>hudson.model.View.Configure</permission>
          <permission>hudson.model.Run.Replay</permission>
          <permission>hudson.model.Item.Configure</permission>
          <permission>hudson.model.View.Read</permission>
          <permission>hudson.model.View.Create</permission>
          <permission>hudson.model.Item.Read</permission>
          <permission>hudson.model.Item.Cancel</permission>
          <permission>hudson.model.Item.Delete</permission>
          <permission>hudson.model.Item.Build</permission>
          <permission>hudson.model.Run.Artifacts</permission>
          <permission>hudson.model.Item.Move</permission>
          <permission>hudson.model.Item.Discover</permission>
          <permission>hudson.model.Run.Update</permission>
        </permissions>
      </template>
      <template name="developers">
        <permissions>
          <permission>hudson.model.Item.Cancel</permission>
          <permission>hudson.model.Item.Delete</permission>
          <permission>hudson.model.Item.Read</permission>
          <permission>hudson.model.Item.Create</permission>
          <permission>hudson.model.Item.Workspace</permission>
          <permission>hudson.model.Item.Build</permission>
          <permission>hudson.model.Run.Replay</permission>
          <permission>hudson.model.Item.Move</permission>
          <permission>hudson.model.Item.Discover</permission>
          <permission>hudson.model.Item.Configure</permission>
          <permission>hudson.model.View.Read</permission>
        </permissions>
      </template>
      <template name="viewers">
        <permissions>
          <permission>hudson.model.Item.Read</permission>
          <permission>hudson.model.Item.Discover</permission>
          <permission>hudson.model.View.Read</permission>
        </permissions>
      </template>
    </permissionTemplates>
    <roleMap type="slaveRoles">
      <role name="all-nodes" pattern=".*">
        <permissions>
          <permission>hudson.model.Computer.Build</permission>
          <permission>hudson.model.Computer.Configure</permission>
          <permission>hudson.model.Computer.Connect</permission>
          <permission>hudson.model.Computer.Create</permission>
          <permission>hudson.model.Computer.Delete</permission>
          <permission>hudson.model.Computer.Disconnect</permission>
        </permissions>
        <assignedSIDs>
          <sid type="GROUP">administrators</sid>
          <sid type="GROUP">developers</sid>
          <sid type="USER">horizon-admin</sid>
          <sid type="USER">admin</sid>
          <sid type="GROUP">authenticated</sid>
          <sid type="USER">authenticated</sid>
        </assignedSIDs>
      </role>
    </roleMap>
    <roleMap type="globalRoles">
      <role name="administrators" pattern=".*">
        <permissions>
          <permission>hudson.model.Hudson.Administer</permission>
        </permissions>
        <assignedSIDs>
          <sid type="GROUP">administrators</sid>
          <sid type="USER">horizon-admin</sid>
          <sid type="USER">admin</sid>
        </assignedSIDs>
      </role>
      <role name="developers" pattern=".*">
        <permissions>
          <permission>hudson.model.Hudson.Read</permission>
          <permission>hudson.model.Item.Create</permission>
          <permission>hudson.model.Computer.Build</permission>
        </permissions>
        <assignedSIDs>
          <sid type="GROUP">developers</sid>
          <sid type="USER">horizon-admin</sid>
          <sid type="USER">admin</sid>
          <sid type="GROUP">authenticated</sid>
          <sid type="USER">authenticated</sid>
        </assignedSIDs>
      </role>
      <role name="viewers" pattern=".*">
        <permissions>
          <permission>hudson.model.Hudson.Read</permission>
        </permissions>
        <assignedSIDs>
          <sid type="GROUP">viewers</sid>
        </assignedSIDs>
      </role>
    </roleMap>
    <roleMap type="projectRoles">
      <role name="developers" pattern=".*" templateName="developers">
        <permissions>
          <permission>hudson.model.Item.Cancel</permission>
          <permission>hudson.model.Item.Delete</permission>
          <permission>hudson.model.Item.Read</permission>
          <permission>hudson.model.Item.Create</permission>
          <permission>hudson.model.Item.Workspace</permission>
          <permission>hudson.model.Item.Build</permission>
          <permission>hudson.model.Run.Replay</permission>
          <permission>hudson.model.Item.Move</permission>
          <permission>hudson.model.Item.Discover</permission>
          <permission>hudson.model.Item.Configure</permission>
          <permission>hudson.model.View.Read</permission>
        </permissions>
        <assignedSIDs>
          <sid type="GROUP">developers</sid>
          <sid type="USER">horizon-admin</sid>
          <sid type="USER">admin</sid>
          <sid type="GROUP">authenticated</sid>
          <sid type="USER">authenticated</sid>
        </assignedSIDs>
      </role>
      <role name="viewers" pattern=".*" templateName="viewers">
        <permissions>
          <permission>hudson.model.Item.Read</permission>
          <permission>hudson.model.Item.Discover</permission>
          <permission>hudson.model.View.Read</permission>
        </permissions>
        <assignedSIDs>
          <sid type="GROUP">viewers</sid>
        </assignedSIDs>
      </role>
    </roleMap>
  </authorizationStrategy>
XML
fi

# ArgoCD
log_info "Configuring ArgoCD OIDC Discovery & In-Cluster Resolution..."
kubectl get configmap argocd-cm -n argocd -o yaml 2>/dev/null | \
  sed 's|url: https://dev.horizon-sdv.com/argocd|url: http://dev.horizon-sdv.com:8080/argocd|g' | \
  sed 's|issuer: https://dev.horizon-sdv.com/auth/realms/horizon|issuer: http://dev.horizon-sdv.com:8080/auth/realms/horizon\n    insecureSkipVerify: true|g' | \
  kubectl apply -f - || true

if [ -n "${ROUTER_IP}" ]; then
  kubectl patch deployment argocd-server -n argocd --type=json -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${ROUTER_IP}\", \"hostnames\": [\"dev.horizon-sdv.com\", \"mcp.dev.horizon-sdv.com\"]}]}]" 2>/dev/null || true
fi

# MTK Connect
log_info "Configuring MTK Connect SAML Entrypoint & Services..."
kubectl get configmap mtk-connect-config -n mtk-connect -o yaml 2>/dev/null | \
  sed 's|https://hostname/auth/realms/horizon/protocol/saml|http://dev.horizon-sdv.com:8080/auth/realms/horizon/protocol/saml|g' | \
  kubectl apply -f - || true

cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mtk-connect-router
  namespace: mtk-connect
spec:
  ports:
  - name: router
    port: 8081
    targetPort: 8081
  - name: auth
    port: 8082
    targetPort: 8082
  selector:
    app.kubernetes.io/name: mtk-connect
  type: ClusterIP
EOF

if [ -n "${ROUTER_IP}" ]; then
  kubectl patch deployment mtk-connect -n mtk-connect --type=json -p="[{\"op\": \"add\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [{\"ip\": \"${ROUTER_IP}\", \"hostnames\": [\"dev.horizon-sdv.com\", \"mcp.dev.horizon-sdv.com\"]}]}]" 2>/dev/null || true
fi

# Enable HTTP-compatible session cookies in MTK Connect
kubectl patch deployment mtk-connect -n mtk-connect --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/1/command", "value": ["/bin/sh", "-c"]},
  {"op": "add", "path": "/spec/template/spec/containers/1/args", "value": ["sed -i '\''s|sameSite:\"none\"|sameSite:\"lax\"|g'\'' Authenticator.js && sed -i '\''s|secure:\"production\"===process.env.NODE_ENV|secure:false|g'\'' Authenticator.js && node runauthenticator.js"]}
]' 2>/dev/null || true

# ------------------------------------------------------------------------------
# 4. Completion Summary
# ------------------------------------------------------------------------------
log_step "Setup Complete!"
echo ""
echo -e "${GREEN}${BOLD}✓ SDV Horizon local development environment is ready!${NC}"
echo ""
echo -e "${BOLD}To access the platform:${NC}"
echo "  1. Run:  ${BOLD}${REPO_ROOT}/port-forward.sh${NC}"
echo "  2. Open: ${BOLD}http://localhost:8080${NC}"
echo ""
echo -e "${BOLD}Credentials:${NC}"
echo "  • Keycloak Master Admin: admin / HorizonDevAdmin2026!"
echo "  • Developer Portal / Jenkins / Gerrit SSO: horizon-admin / HorizonDevUser2026!"
echo ""

# Run Verification Suite
if [ -f "${REPO_ROOT}/tools/scripts/test-horizon.sh" ]; then
  log_step "4. Running Automated Verification Suite"
  kubectl port-forward -n horizon svc/horizon-router 8080:80 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  bash "${REPO_ROOT}/tools/scripts/test-horizon.sh" 8080 || true
  kill $PF_PID 2>/dev/null || true
fi
