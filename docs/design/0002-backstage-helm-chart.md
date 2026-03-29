---
id: DESIGN-0002
title: "Backstage Helm Chart"
status: Draft
decision: deferred
author: Donald Gifford
created: 2026-03-29
---

<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0002: Backstage Helm Chart

**Status:** Draft (Deferred) **Author:** Donald Gifford **Date:** 2026-03-29

> **Decision (2026-03-29):** We will first try using the official Backstage Helm
> chart with `postgresql.enabled: false` and kustomize overlays for the extra
> resources (CNPG Cluster CR, Gateway API HTTPRoute, cert-manager Certificate).
> The official chart already supports external PostgreSQL via environment
> variables, so the main gaps are just the HTTPRoute and CNPG CR — which can be
> managed as standalone manifests alongside the Helm release.
>
> This design doc is retained as a reference. If the official chart + kustomize
> approach proves insufficient (e.g., the chart's extension points are too
> limited, or maintaining sidecar manifests becomes unwieldy), we can revisit
> and implement this custom chart design.

## Overview

A first-party Helm chart for [Backstage](https://backstage.io) that replaces the
official chart's Bitnami PostgreSQL subchart dependency with flexible PostgreSQL
configuration: direct env-var-based connection (for any PostgreSQL setup) or an
embedded CloudNativePG (CNPG) `Cluster` CR as the default database backend. The
chart also replaces the classic Ingress with Gateway API `HTTPRoute` as the
primary ingress path, matching the conventions established by the FleetDM chart.

## Goals and Non-Goals

### Goals

- Replace the Bitnami PostgreSQL subchart with CNPG `Cluster` CR (operator
  deployed separately) as the default database option
- Support any external PostgreSQL by exposing database connection env vars
  directly
- Use Gateway API `HTTPRoute` as the default ingress (matching FleetDM chart
  conventions)
- Support classic `Ingress` as a disabled-by-default alternative
- Follow the `existingSecret` pattern throughout — chart generates secrets by
  default, overridable with external secret references
- Remove all Bitnami chart dependencies (common, postgresql)
- Zero-dependency chart (no subchart dependencies in `Chart.yaml`)
- Full test coverage: helm-unittest, helm test hooks, chart-testing CI values
- Automated `appVersion` tracking via Renovate

### Non-Goals

- Installing the CNPG operator (deployed separately, must be watching the
  namespace)
- Bundling or managing Backstage plugins (users build their own Backstage image)
- Providing a default Backstage app-config — users must supply their own via
  ConfigMap or values
- Managing TLS termination in the application (TLS terminates at the
  gateway/ingress controller)
- Supporting the Bitnami PostgreSQL subchart as a fallback option
- Network policies (may be added in a future iteration)

## Background

The [official Backstage Helm chart](https://github.com/backstage/charts)
(v2.6.3) depends on:

1. **Bitnami Common** (v2.10.0) — helper templates for image formatting, labels,
   etc.
2. **Bitnami PostgreSQL** (v12.10.0) — optional PostgreSQL subchart

These Bitnami dependencies cause the same problems encountered with the FleetDM
upstream chart: frequent breaking changes on version bumps, opinionated defaults
that conflict with production patterns, and tight coupling to Bitnami's
image/secret naming conventions.

The official chart provides:

- Deployment with configurable replicas, probes, and security context
- ConfigMap-based app-config injection
- Classic Ingress (disabled by default)
- HPA, PDB, ServiceMonitor
- Network policies (ingress + egress)

This design replaces the database layer with CNPG (a Kubernetes-native
PostgreSQL operator) and adds Gateway API support, while preserving the useful
patterns from the official chart.

### Why CNPG over Bitnami PostgreSQL?

| Aspect         | Bitnami PostgreSQL             | CloudNativePG                                 |
| -------------- | ------------------------------ | --------------------------------------------- |
| Approach       | StatefulSet via Helm subchart  | Kubernetes operator + CR                      |
| HA             | Manual replication config      | Automatic failover, built-in                  |
| Backups        | External tooling required      | Barman S3/GCS/Azure built-in                  |
| Upgrades       | Chart version bumps            | Operator-managed rolling updates              |
| Recovery       | Manual PITR via external tools | Native PITR support                           |
| Service naming | `<release>-postgresql`         | `<cluster>-rw`, `<cluster>-ro`, `<cluster>-r` |

CNPG is the CNCF-accepted operator for PostgreSQL on Kubernetes and provides a
production-grade database lifecycle without Helm subchart coupling.

## Detailed Design

### Key Design Decisions

- **No Bitnami dependencies.** The chart has zero subchart dependencies. All
  helpers are self-contained in `_helpers.tpl`.
- **CNPG as default database.** When `cnpg.enabled: true` (the default), the
  chart creates a CNPG `Cluster` CR. The CNPG operator must be deployed
  separately.
- **External PostgreSQL support.** When `cnpg.enabled: false`, users provide
  connection details via `database.host`, `database.port`, `database.name`,
  `database.user`, and a secret reference for the password. This supports any
  PostgreSQL: RDS, Cloud SQL, Aurora, self-managed, etc.
- **existingSecret pattern.** Chart generates random credentials by default with
  `helm.sh/resource-policy: keep`. Any secret can be overridden with
  `existingSecret`.
- **Gateway API HTTPRoute as default.** Same pattern as FleetDM:
  `httpRoute.enabled: true` by default, guarded on non-empty `parentRefs`.
  Classic Ingress supported but disabled.
- **User-supplied Backstage image.** The chart defaults to the upstream
  `ghcr.io/backstage/backstage` image but users are expected to build and
  provide their own image with plugins baked in.
- **App-config via ConfigMap or inline values.** Users can provide Backstage
  configuration via `backstage.appConfig` (rendered into a ConfigMap) or
  reference an existing ConfigMap. The app-config is mounted as a file and
  passed via `--config` argument.

### Prerequisites and Dependencies

| Dependency       | Required Version                                    | How to Validate                                                 |
| ---------------- | --------------------------------------------------- | --------------------------------------------------------------- |
| Kubernetes       | 1.25+                                               | `kubectl version`                                               |
| Helm             | 3.10+                                               | `helm version`                                                  |
| CNPG Operator    | 1.22+ (when `cnpg.enabled: true`)                   | `kubectl get deployment cnpg-controller-manager -n cnpg-system` |
| Gateway API CRDs | v1 (when `httpRoute.enabled: true`)                 | `kubectl get crd httproutes.gateway.networking.k8s.io`          |
| cert-manager     | v1.12+ (when `httpRoute.certManager.enabled: true`) | `kubectl get crd certificates.cert-manager.io`                  |

The CNPG operator must be deployed and watching the target namespace **before**
installing this chart with `cnpg.enabled: true`.

### Chart Layout

```
charts/backstage/
├── Chart.yaml
├── README.md                   # generated by helm-docs
├── README.md.gotmpl            # helm-docs template
├── values.yaml
├── values.schema.json
├── ci/
│   ├── default-values.yaml     # minimal ct install values (CNPG disabled, stub DB)
│   └── ha-values.yaml          # HPA, PDB, CNPG enabled, HTTPRoute
├── templates/
│   ├── _helpers.tpl
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml          # Backstage app-config ConfigMap
│   ├── httproute.yaml          # Gateway API HTTPRoute + optional cert-manager Certificate
│   ├── ingress.yaml            # Classic Ingress (disabled by default)
│   ├── serviceaccount.yaml
│   ├── hpa.yaml
│   ├── pdb.yaml
│   ├── secret.yaml             # generated creds, skipped when existingSecret is set
│   ├── cnpg-cluster.yaml       # CloudNativePG Cluster CR
│   ├── servicemonitor.yaml     # Prometheus ServiceMonitor (disabled by default)
│   ├── NOTES.txt
│   └── tests/
│       ├── test-postgresql-connection.yaml
│       └── test-backstage-health.yaml
└── tests/                      # helm-unittest files
    ├── deployment_test.yaml
    ├── secret_test.yaml
    ├── configmap_test.yaml
    ├── cnpg_cluster_test.yaml
    ├── httproute_test.yaml
    ├── ingress_test.yaml
    ├── hpa_test.yaml
    ├── pdb_test.yaml
    ├── service_test.yaml
    ├── serviceaccount_test.yaml
    └── servicemonitor_test.yaml
```

### Helper Functions (`_helpers.tpl`)

Beyond standard name/label helpers:

- `backstage.image` — combines `image.registry`, `image.repository`, and
  `image.tag`, falling back to `.Chart.AppVersion` when tag is empty
- `backstage.postgresqlSecretName` — returns `database.existingSecret` if set,
  otherwise chart-generated secret name
- `backstage.cnpgSecretName` — returns `cnpg.existingSecret` if set, otherwise
  chart-generated CNPG credentials secret name
- `backstage.postgresqlHost` — returns `database.host` if set; derives
  `<clusterName>-rw.<namespace>.svc.cluster.local` when `cnpg.enabled`;
  otherwise calls `fail` with message:
  `"database.host is required when cnpg.enabled is false"`
- `backstage.postgresqlPort` — returns `database.port` (default 5432)
- `backstage.appConfigName` — returns `backstage.existingConfigMap` if set,
  otherwise chart-generated ConfigMap name

### Secrets

Two conditional secrets, each skipped when its corresponding `existingSecret` is
set:

1. **PostgreSQL secret** — `database.existingSecret` controls. Contains the
   password key (`database.passwordKey`, default `postgresql-password`).
2. **CNPG credentials secret** — `cnpg.existingSecret` controls. Contains keys:
   `username`, `password`. Used by the CNPG `Cluster` CR for bootstrap
   credentials.

All generated secrets use `helm.sh/resource-policy: keep` to survive upgrades.

### Deployment

The Backstage Deployment wires database connection via environment variables:

- `POSTGRES_HOST` — from `backstage.postgresqlHost` helper
- `POSTGRES_PORT` — from `backstage.postgresqlPort` helper (default `"5432"`)
- `POSTGRES_USER` — from `database.user` value
- `POSTGRES_PASSWORD` — secretKeyRef from `backstage.postgresqlSecretName`
- `POSTGRES_DB` — from `database.name` value

Additional env vars:

- `backstage.extraEnv` — list of arbitrary env vars for user configuration
- `backstage.extraEnvFrom` — list of envFrom sources (ConfigMapRef, SecretRef)

The container runs with configurable security context. Default:

- `readOnlyRootFilesystem: true`
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`

Mounts:

- `/app/app-config` — ConfigMap volume with Backstage app-config
- `/tmp` — emptyDir for scratch space

Container port: 7007 (HTTP backend).

Health probes:

- Readiness: `GET /.backstage/health/v1/readiness` port 7007
- Liveness: `GET /.backstage/health/v1/liveness` port 7007
- Startup: same as readiness with higher failure threshold

Default command:
`["node", "packages/backend", "--config", "/app/app-config/app-config.yaml"]`

### CNPG Cluster CR (`cnpg-cluster.yaml`)

Gated behind `cnpg.enabled` (default: true). Creates a `postgresql.cnpg.io/v1`
`Cluster` resource.

Key fields:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: { { include "backstage.cnpgClusterName" . } }
  annotations:
    argocd.argoproj.io/sync-options: "ServerSideApply=true"
spec:
  instances: { { .Values.cnpg.instances } }
  bootstrap:
    initdb:
      database: { { .Values.database.name } }
      owner: { { .Values.database.user } }
      secret:
        name: { { include "backstage.cnpgSecretName" . } }
  storage:
    size: { { .Values.cnpg.storage.size } }
    storageClass: { { .Values.cnpg.storage.storageClassName } }
  resources: { { .Values.cnpg.resources } }
  postgresql:
    parameters: { { .Values.cnpg.postgresql.parameters } }
  backup: { { .Values.cnpg.backup } } # optional, gated
```

CNPG services created automatically by the operator:

- `<clusterName>-rw` — primary (read-write)
- `<clusterName>-ro` — replicas (read-only)
- `<clusterName>-r` — any instance (read)

The `backstage.postgresqlHost` helper points to the `-rw` service.

### App-Config ConfigMap (`configmap.yaml`)

Rendered when `backstage.appConfig` is non-empty and
`backstage.existingConfigMap` is not set. The ConfigMap contains the
user-provided Backstage `app-config.yaml` content.

Users who manage their app-config externally (e.g., in a Git-synced ConfigMap or
ArgoCD-managed resource) set `backstage.existingConfigMap` to reference it.

### HTTPRoute (`httproute.yaml`)

Same pattern as FleetDM: renders two documents when both flags are enabled:

1. `cert-manager.io/v1 Certificate` — only when `httpRoute.certManager.enabled`
   is true
2. `gateway.networking.k8s.io/v1 HTTPRoute` — always when `httpRoute.enabled` is
   true and `parentRefs` is non-empty

### Ingress (`ingress.yaml`)

Classic `networking.k8s.io/v1 Ingress` resource, disabled by default. Provided
for environments not yet on Gateway API. Supports standard annotations, TLS, and
custom paths.

### ServiceMonitor (`servicemonitor.yaml`)

Optional Prometheus `ServiceMonitor` resource, disabled by default. Scrapes the
`/metrics` endpoint on port 7007 when `serviceMonitor.enabled: true`.

### Minimum Resource Requirements

| Component          | CPU Request | Memory Request | Notes                                    |
| ------------------ | ----------- | -------------- | ---------------------------------------- |
| Backstage          | 250m        | 512Mi          | Single replica baseline; scale via HPA   |
| CNPG instance (x3) | 500m        | 512Mi          | Per instance; 3-instance cluster default |

A minimal production deployment (Backstage + 3-instance CNPG) requires
approximately **1.75 CPU / 2Gi memory** in requests across all components.

## API / Interface Changes

### `values.yaml` Key Sections

**Backstage app config:**

```yaml
backstage:
  replicaCount: 1
  image:
    registry: ghcr.io
    repository: backstage/backstage
    tag: "" # defaults to appVersion
    pullPolicy: IfNotPresent
  command: ["node", "packages/backend"]
  args: ["--config", "/app/app-config/app-config.yaml"]
  appConfig: {} # inline app-config YAML, rendered to ConfigMap
  existingConfigMap: "" # reference external ConfigMap instead
  extraEnv: [] # additional env vars
  extraEnvFrom: [] # additional envFrom sources
  containerPort: 7007
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      memory: 1Gi
```

**Database (PostgreSQL):**

```yaml
database:
  host: "" # auto-derived from CNPG when empty
  port: "5432"
  name: backstage
  user: backstage
  passwordKey: postgresql-password
  existingSecret: "" # override chart-generated secret
```

**CNPG cluster (default database):**

```yaml
cnpg:
  enabled: true
  clusterName: "" # defaults to <release>-cnpg
  instances: 3
  image:
    repository: ghcr.io/cloudnative-pg/postgresql
    tag: "16.4"
  storage:
    size: 10Gi
    storageClassName: ""
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      memory: 1Gi
  postgresql:
    parameters: {} # PostgreSQL configuration parameters
  backup:
    enabled: false
    barmanObjectStore: {}
    retentionPolicy: "30d"
  existingSecret: "" # override chart-generated CNPG credentials
```

**HTTPRoute (default ingress):**

```yaml
httpRoute:
  enabled: true
  hostname: ""
  parentRefs: [] # required — chart renders nothing if empty
  certManager:
    enabled: false
    clusterIssuer: ""
    certificateName: ""
```

**Ingress (alternative):**

```yaml
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts: []
  tls: []
```

**Standard Kubernetes:**

```yaml
serviceAccount:
  create: true
  annotations: {}
  name: ""
  automountServiceAccountToken: false

service:
  type: ClusterIP
  port: 7007

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

podDisruptionBudget:
  enabled: false
  minAvailable: 1

serviceMonitor:
  enabled: false
  interval: 30s
  path: /metrics

nodeSelector: {}
tolerations: []
affinity: {}
```

### `values.schema.json` Constraints

- `database.name`, `database.user`, `database.passwordKey` — required non-empty
  strings
- `cnpg.instances` — enum of `[1, 2, 3, 5]` (odd values preferred for HA quorum)
- `autoscaling.targetCPUUtilizationPercentage` — integer 1-100
- `backstage.containerPort` — integer, minimum 1

## Data Model

No persistent data owned by the chart itself. The CNPG `Cluster` CR manages
PostgreSQL storage via PVCs configured through `cnpg.storage.size` and
`cnpg.storage.storageClassName`. The CNPG operator handles volume lifecycle,
backups, and recovery.

## Testing Strategy

### Helm Test Hooks (`templates/tests/`)

- **test-postgresql-connection.yaml** — `postgres:16` pod runs `SELECT 1`
  against the PostgreSQL host (CNPG `-rw` service or external host)
- **test-backstage-health.yaml** — `curlimages/curl` hits
  `/.backstage/health/v1/readiness` on Backstage service (hook-weight 5, runs
  after DB test)

All test pods include full security contexts (pod + container level) to pass
Trivy scans.

### Unit Tests (`tests/`, helm-unittest)

11 test suites covering all templates:

- **deployment_test.yaml** — replicas, image tag, env vars for all DB
  configurations, autoscaling interaction, security context, volume mounts,
  app-config mount
- **secret_test.yaml** — conditional rendering for PostgreSQL/CNPG secrets,
  existingSecret skip, resource-policy keep annotation
- **configmap_test.yaml** — inline appConfig rendering, existingConfigMap skip
- **cnpg_cluster_test.yaml** — enabled/disabled rendering, cluster name,
  instances, secret name derivation, storage config, backup toggle, ArgoCD SSA
  annotation
- **httproute_test.yaml** — enabled/disabled rendering, parentRefs guard,
  Certificate + HTTPRoute combo
- **ingress_test.yaml** — enabled/disabled, className, annotations, TLS config
- **hpa_test.yaml** — enabled/disabled rendering, min/max replicas, CPU target
- **pdb_test.yaml** — enabled/disabled rendering, minAvailable
- **service_test.yaml** — service type, port
- **serviceaccount_test.yaml** — create/skip, annotations, automount disabled
- **servicemonitor_test.yaml** — enabled/disabled, interval, path

### Chart Testing CI Values (`ci/`)

- **default-values.yaml** — CNPG disabled, stub `database.host`, httpRoute
  disabled. Resources render and apply cleanly in Kind without the CNPG
  operator.
- **ha-values.yaml** — CNPG enabled, HPA, PDB, httpRoute with stub parentRefs to
  exercise all code paths.

### Integration Testing Gaps

Same approach as FleetDM: `ct install` with stub addresses verifies resources
render and apply, but does not test full Backstage startup (database connection,
plugin loading). Full e2e testing requires the CNPG operator in Kind. For
initial release, full integration is validated manually via `helm test` against
a real cluster.

## Migration / Rollout Plan

### Implementation Phases

| Phase | What                                                                                                                     | Tooling       |
| ----- | ------------------------------------------------------------------------------------------------------------------------ | ------------- |
| 1     | Scaffold: `Chart.yaml`, `values.yaml`, `values.schema.json`                                                              | manual        |
| 2     | `_helpers.tpl` — name, label, secret, address, app-config helpers                                                        | hand-rolled   |
| 3     | Core templates: `secret.yaml`, `configmap.yaml`, `serviceaccount.yaml`, `deployment.yaml`, `service.yaml`                | hand-rolled   |
| 4     | Extended templates: `cnpg-cluster.yaml`, `httproute.yaml`, `ingress.yaml`, `hpa.yaml`, `pdb.yaml`, `servicemonitor.yaml` | hand-rolled   |
| 5     | Helm test hooks: PostgreSQL connection, Backstage health                                                                 | hand-rolled   |
| 6     | Unit tests for each template                                                                                             | helm-unittest |
| 7     | Annotate `values.yaml`, write `README.md.gotmpl`, generate docs                                                          | helm-docs     |
| 8     | Write `ci/` values files, validate lint passes locally                                                                   | ct lint       |

### ArgoCD Integration

- **ignoreDifferences** on the Backstage Application to suppress CNPG operator
  status field drift:

  ```yaml
  ignoreDifferences:
    - group: postgresql.cnpg.io
      kind: Cluster
      jsonPointers:
        - /status
  ```

- **Server-side apply** via annotation on the CNPG `Cluster` CR so the operator
  can own its own fields without conflicting with ArgoCD's three-way merge.
- **Secret lifecycle** — generated secrets use `helm.sh/resource-policy: keep`.
  When using `existingSecret`, the chart skips creating secrets entirely.

## Open Questions

1. **Backstage app-config strategy:** Should the chart support multiple
   app-config files (e.g., `app-config.yaml` + `app-config.production.yaml`)
   mounted from multiple ConfigMaps, or is a single ConfigMap sufficient? The
   official chart supports a single `appConfig` block.

2. **CNPG PostgreSQL version:** Should we default to PostgreSQL 16.4 or track
   the latest 16.x? The CNPG operator supports in-place minor version upgrades.

3. **CNPG backup configuration:** How much of the CNPG backup spec should we
   expose in values? Minimal (just `barmanObjectStore` passthrough) or
   structured with individual fields for S3/GCS/Azure?

4. **Init containers for migrations:** Backstage runs database migrations on
   startup. Should we add an optional init container that waits for PostgreSQL
   readiness before the main container starts, or rely on Backstage's built-in
   retry logic?

5. **ServiceMonitor vs PodMonitor:** The official chart uses `ServiceMonitor`.
   Should we follow suit or is there a reason to prefer `PodMonitor`?

6. **Backstage container user/group:** What UID/GID does the official Backstage
   image run as? Need to verify for security context configuration.

## References

- [Backstage](https://backstage.io)
- [Official Backstage Helm Chart](https://github.com/backstage/charts)
- [CloudNativePG](https://cloudnative-pg.io)
- [CloudNativePG Cluster Spec](https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/)
- [CNPG Service Management](https://cloudnative-pg.io/documentation/current/service_management/)
- [Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)
- [RFC-0001: Helm Charts Repository Layout and Conventions](../rfc/0001-helm-charts-repository-layout-and-conventions.md)
- [DESIGN-0001: FleetDM Helm Chart](0001-fleetdm-helm-chart.md)
