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

## Using the result

The pipeline's deliverable is the **workstation config** `voltron-demo-latest`, not a
running workstation. Creating workstations from it is deliberately left to the
developer — there is no launch pipeline, because a workstation is a long-lived,
per-person, billable resource whose lifecycle should not be tied to a CI run.

Launch one from the Cloud Console (**Cloud Workstations → Workstations → Create**,
choosing the `voltron-demo-latest` config), or from the CLI:

```bash
gcloud workstations create "${USER}-voltron" \
    --project="${PROJECT}" --region="${REGION}" \
    --cluster=sdv-cluster --config=voltron-demo-latest

gcloud workstations start "${USER}-voltron" \
    --project="${PROJECT}" --region="${REGION}" \
    --cluster=sdv-cluster --config=voltron-demo-latest
```

The remote desktop (GNOME streamed in-browser via Apache Guacamole) is served on
port 80, i.e. at the workstation's own hostname:

```bash
gcloud workstations describe "${USER}-voltron" \
    --project="${PROJECT}" --region="${REGION}" \
    --cluster=sdv-cluster --config=voltron-demo-latest \
    --format='value(host)'
# -> https://<host>
```

`/home` is restored from the promoted snapshot, so `~/Workspace/carla-installation`
and a fully built `~/Workspace/aaos-26q2` are present on first boot. See
`/google/sdv-bashrc-hook/README` on the workstation for the demo quickstart
(`launch_2vm`, then `launch_carla`).

Remember to stop workstations when idle — the config requests an `n1-standard-32`
with an attached NVIDIA T4.

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
and `roles/compute.storageAdmin`.

`templates/kcc-iam.yaml` expresses these as Config Connector `IAMPolicyMember`
CRs in the `gcp` namespace (which holds a `ConfigConnectorContext`; the
`workflows` one is owned and torn down by `workloads-android`).
`IAMPolicyMember` is additive — it manages only the `(member, role)` pairs it
names and leaves other bindings on the project untouched.

**These are disabled by default** (`spec.iam.enabled: false`).

> Config Connector can only manage project IAM if the service account named by
> the `ConfigConnectorContext` — currently `gke-config-connector-sa` — holds
> `roles/resourcemanager.projectIamAdmin`. It currently holds no project roles,
> so the CRs fail with `Error 403: The caller does not have permission`.
>
> This is worse than a no-op: the CRs sit in **sync-wave 1**, and Argo CD will
> not advance to later waves while a wave is unhealthy — so a failing grant
> silently prevents the WorkflowTemplates (wave 7) and Sensors (wave 8) from
> being created at all.

Until the platform grants Config Connector that role, grant the two roles
out-of-band:

```bash
SA="serviceAccount:gke-argo-workflows-elevated-sa@${PROJECT}.iam.gserviceaccount.com"
for ROLE in roles/workstations.admin roles/compute.storageAdmin; do
  gcloud projects add-iam-policy-binding "${PROJECT}" \
      --member="${SA}" --role="${ROLE}" --condition=None
done
```

then flip `spec.iam.enabled: true` to hand ownership back to Config Connector.

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `horizonSubmittedFrom` | no | Populated by the Developer Portal / Horizon CLI. Leave empty. |

There are no credential parameters: both pipelines authenticate as the cluster's
own service account. Everything else — repository URL and revision, image names,
workstation cluster and builder config — is deploy-time configuration in
[`argo-workflows/values.yaml`](argo-workflows/values.yaml), not a submit-time
parameter.

> [!IMPORTANT]
> Parameters are mapped **positionally** by the Sensors
> (`spec.arguments.parameters.N.value`). If you add, remove or reorder a
> parameter in `workflowtemplates.yaml`, you must update `sensors.yaml` to match.

### How credentials work

`sdv-demos` is not public, but you do **not** supply anything. Each
credential-consuming step runs an init container that mints a short lived OAuth
token for the workflow service account from the GKE metadata server, and writes
it to a memory-backed `emptyDir` shared with the main container.

This is not merely a convenience — a developer's `~/.gitcookies` **cannot work
here at all**. The Git-on-Borg `sdv` host grants its human readers almost
entirely through MDB `prod_group` and `prod_user` entries, and those resolve only
over `sso://` and `rpc://`, neither of which exists inside a GKE pod. Over HTTPS
any credential resolves a *GAIA* identity, which matches nothing in that host's
ACL, so requests fail with `PERMISSION_DENIED_BY_HOST_ACL` regardless of how
fresh the cookie is. The host does authorise `robot` readers, and a service
account is a GAIA identity — hence this design.

> [!IMPORTANT]
> **Prerequisite.** The workflow service account must be listed as a `robot`
> reader on the `sdv` host, in both `host_acl` (checked first) and the
> `sdv/experimental` directory ACL, in
> `//depot/google3/configs/production/gerritcodereview/prod/sdv/config.textproto`:
>
> ```textproto
> robot: "gke-argo-workflows-elevated-sa@<project>.iam.gserviceaccount.com"
> ```
>
> Changes there need approval from `sdv-gob-owner`. Without it, `voltron-demo-init`
> fails fast with `PERMISSION_DENIED_BY_HOST_ACL`.

The token is deliberately never exposed as a workflow parameter or an output
parameter, because Argo has no masked-parameter support and both would persist
the value in the Workflow object for anyone who can read workflows in this
namespace.

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
