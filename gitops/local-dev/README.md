# SDV Horizon - Local Development Environment

This directory contains manifests and scripts for running and accessing SDV Horizon locally via single-port `kubectl port-forward` without requiring external Google Cloud Application Load Balancers, public domains, or public SSL certificates.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Developer Workstation                                       │
│                                                             │
│  Browser: http://localhost:8080                             │
│       │                                                     │
│       ▼                                                     │
│  port-forward.sh (8080 -> svc/horizon-router:80)            │
└───────┬─────────────────────────────────────────────────────┘
        │
        ▼ (Kubernetes Cluster: SDV Horizon)
┌─────────────────────────────────────────────────────────────┐
│ svc/horizon-router (NGINX Reverse Proxy)                    │
│                                                             │
│  /                 -> svc/landingpage.horizon:80            │
│  /developer-portal -> svc/horizon-dev-portal:80             │
│  /jenkins          -> svc/jenkins.jenkins:8080              │
│  /auth             -> svc/keycloak-keycloakx-http:8080      │
│  /gerrit           -> svc/gerrit-service.gerrit:8080        │
│  /argocd           -> svc/argocd-server.argocd:80           │
│  /grafana          -> svc/grafana.monitoring:80             │
│  /headlamp         -> svc/headlamp.headlamp:80              │
│  /workflows        -> svc/argo-workflows-server:2746        │
│  /api              -> svc/horizon-api.horizon-api:8082      │
└─────────────────────────────────────────────────────────────┘
```

## Files

- **`horizon-router.yaml`**: Kubernetes manifest defining the ConfigMap, Deployment, and Service for `horizon-router`.
  - Configures dynamic port mapping (`map $http_host $forwarded_port`) so `X-Forwarded-Port` and `X-Forwarded-Host` preserve the developer's exact port (`8080`).
  - Configures `proxy_redirect` rewriting rules so internal cluster service redirects (`http://keycloak-keycloakx-http...`) are translated to `http://$http_host/auth/`.
- **`setup-local-dev.sh`**: One-command setup script that:
  - Deploys `horizon-router.yaml`.
  - Disables SSL enforcement (`sslRequired=NONE`) in Keycloak for HTTP localhost.
  - Adds `http://localhost:8080/*` and other local ports to Keycloak clients.
  - Configures Jenkins Keycloak secret for in-cluster OIDC discovery.
- **`../../port-forward.sh`**: Root bash script that maintains port forwarding to `horizon-router` (port 8080) and secondary direct ports with auto-reconnection.

## Usage

1. **Apply local development setup**:
   ```bash
   ./gitops/local-dev/setup-local-dev.sh
   ```

2. **Start port forwarding**:
   ```bash
   ./port-forward.sh
   ```

3. **Open the browser**:
   Navigate to [http://localhost:8080](http://localhost:8080).
