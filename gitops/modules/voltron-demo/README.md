<!--
Copyright (c) 2026 Accenture, All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# voltron-demo

Builds, snapshots and validates the **SDV Voltron Demo** Cloud Workstation image:
Android Studio for Platform (ASfP) plus CARLA 0.9.15, a SOME/IP bridge and AAOS
demo utilities.

The Dockerfile and every asset it copies live in the internal Git-on-Borg
repository [`sdv-demos`](https://sdv.googlesource.com/experimental/sdv-demos) and
are cloned at run time. Nothing is vendored in this repository.

## Layout

```text
gitops/modules/voltron-demo/
├── Chart.yaml
├── values.yaml                               # Module Manager injection schema
├── portal/overview.html                      # Developer Portal page
├── templates/
│   ├── module-overview-http.yaml
│   └── application-argo-workflows.yaml       # child Argo CD Application
└── argo-workflows/
    ├── Chart.yaml
    ├── values.yaml                           # all deploy-time configuration
    ├── files/                                # step bodies, mounted at /scripts
    │   ├── build-snapshot.sh
    │   ├── test-artifacts.sh
    │   ├── promote-snapshot.sh
    │   └── test_artifacts.bats               # acceptance suite, runs on the workstation
    └── templates/
        ├── _helpers.tpl
        ├── workflowtemplates.yaml            # voltron-demo-init + voltron-demo-execute
        ├── configmap-scripts.yaml            # publishes files/ to the workflow namespace
        ├── kcc-iam.yaml                      # IAMPolicyMember grants (Config Connector)
        └── sensors.yaml
```

Step bodies live under `files/` rather than as inline `args:` blocks so they can be
read, diffed, shell-linted and executed outside the cluster. This mirrors
`workloads-common/prepare-github-app-git-creds`, which mounts
`files/github_app_installation_token.py` the same way.

## Pipelines

### `voltron-demo-init`

Preflight. Validates the supplied credentials against `sdv-demos` and confirms the
configured revision exists. Run this first: it fails in seconds where the build
would fail after tens of minutes.

### `voltron-demo-execute`

| # | Task | What it does |
|---|------|--------------|
| 1 | `prepare-gob-git-creds` | Converts the supplied gitcookies into a per-run `{{workflow.uid}}-sdv-demos-git-creds` Secret. |
| 2 | `build-image` | Delegates to the shared `common-docker-image-build` ClusterWorkflowTemplate to build and push the image. |
| 3 | `build-snapshot` | Provisions a builder workstation, then snapshots its persistent disk. |
| 4 | `test-artifacts` | Boots a GPU test workstation from the snapshot and runs `files/test_artifacts.bats` on it. |
| 5 | `promote-snapshot` | Moves the `is-latest=true` label onto the validated snapshot **and** publishes the `voltron-demo-latest` workstation config built from it. |

An `onExit` handler deletes the credentials Secret whatever the outcome.

The acceptance suite is uploaded to the test workstation as a file and executed
with `bats`, rather than being inlined into a `gcloud workstations ssh --command`
string. `bats` is expected to be present in the image; it is installed by the
`sdv-demos` Dockerfile.

## Why `gcloud` and not Config Connector (KCC)

Per the horizon-dev module conventions, a module should declare its GCP resources
as Config Connector CRs rather than Terraform. This module does that **for its
IAM** (`templates/kcc-iam.yaml`), but drives Cloud Workstations and snapshots
through `gcloud`. The reasons are specific rather than stylistic:

* **No CRDs exist for most of it.** The cluster runs the GKE Config Connector
  add-on at **v1.126.0**, which ships `WorkstationCluster` but neither
  `WorkstationConfig` nor `Workstation`. Upstream KCC only promoted
  `WorkstationConfig` to `v1beta1` in **1.132.0**, and the GKE add-on omits alpha
  CRDs. Its version is chosen by Google and tied to the GKE control-plane version,
  so it cannot be bumped from this repo.
* **The disk name only exists at runtime.** The snapshot source is discovered with
  `gcloud compute disks list --filter=labels.workstation_id=…` after the builder
  workstation has started. A Helm-rendered CR cannot reference it.
* **The lifecycle is one-shot, not reconciled.** `create → start → stop → snapshot
  → delete` is imperative by nature, and KCC's default deletion policy would
  delete the promoted snapshot along with its CR.

The one resource that *would* suit KCC is the long-lived `voltron-demo-latest`
config produced by `promote-snapshot`. Revisit this if the cluster ever moves to
Config Connector ≥ 1.132.

## IAM

The pipeline runs as `workflows/workflow-executor-elevated`, bound by Workload
Identity to `gke-argo-workflows-elevated-sa`. It needs `roles/workstations.admin`
and `roles/compute.storageAdmin`, granted as `IAMPolicyMember` CRs in the `gcp`
namespace (which holds a `ConfigConnectorContext`; the `workflows` one is owned
and torn down by `workloads-android`).

`IAMPolicyMember` is additive — it manages only the `(member, role)` pairs it
names and leaves other bindings on the project untouched. Set
`spec.iam.enabled: false` in `argo-workflows/values.yaml` if these roles are
granted out-of-band instead.

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `horizonSubmittedFrom` | no | Populated by the Developer Portal / Horizon CLI. Leave empty. |
| `gobGitcookiesB64` | **yes** | Base64 of your raw `~/.gitcookies`, single line. |

Everything else — repository URL and revision, image names, workstation cluster
and builder config — is deploy-time configuration in
[`argo-workflows/values.yaml`](argo-workflows/values.yaml), not a submit-time
parameter.

> [!IMPORTANT]
> Parameters are mapped **positionally** by the Sensors
> (`spec.arguments.parameters.N.value`). If you add, remove or reorder a
> parameter in `workflowtemplates.yaml`, you must update `sensors.yaml` to match.

### Supplying credentials

`sdv-demos` is not public, so every run needs your personal Git-on-Borg cookie:

```bash
base64 -w0 ~/.gitcookies
```

Paste the output into `gobGitcookiesB64`.

This mirrors the existing precedent in
`workloads/android/pipelines/builds/aaos_sdv_builder`, which takes
`GERRIT_GITCOOKIES_BASE64` as a per-run, non-stored parameter. Short-lived
personal credentials are deliberately **not** stored in Secret Manager; that tier
is reserved for long-lived platform-owned credentials.

> [!CAUTION]
> Git-on-Borg cookies expire after roughly 20 hours — supply a fresh value each
> run. Argo has no masked-parameter mechanism, so the value is persisted in the
> Workflow CR and is readable by anyone with read access to workflows in this
> namespace. The pipeline never logs the value itself, only its SHA-256 digest.

## Images

| Role | Image |
|------|-------|
| Base, consumed read-only | `<region>-docker.pkg.dev/<project>/horizon-sdv/android-studio-for-platform:latest` |
| Produced by this module | `<region>-docker.pkg.dev/<project>/horizon-sdv/voltron-demo:latest` |

> [!NOTE]
> The ASfP base image is built and published by the separate `horizon-asfp`
> workstation-image pipeline. This module must never write that tag; doing so
> would silently replace the platform's base image.

## Dependencies

Hard dependency on **`workloads-common`**, which publishes the
`common-docker-image-build` ClusterWorkflowTemplate.

That template derives its build context from the Dockerfile directory, which is
why `sdv-demos` keeps its Dockerfile at the repository root. It runs buildkit, so
the `# syntax=docker/dockerfile:1.4` directive and the `COPY --chmod=` flags used
throughout that Dockerfile are honoured — Kaniko would not honour them reliably.

## Verifying changes

```bash
helm lint gitops/modules/voltron-demo
helm lint gitops/modules/voltron-demo/argo-workflows
helm template voltron gitops/modules/voltron-demo/argo-workflows \
  --set parentModuleName=voltron-demo \
  --set gcpProjectId=<project> --set gcpRegion=<region>

kubectl get modulecatalog cluster -n module-manager -o yaml
horizon catalog get
horizon workflow submit --module voltron-demo --template voltron-demo-init --output json
```
