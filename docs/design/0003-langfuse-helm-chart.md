---
id: DESIGN-0003
title: "Langfuse Helm chart"
status: Accepted
author: Donald Gifford
created: 2026-05-04
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0003: Langfuse Helm chart

**Status:** Accepted
**Author:** Donald Gifford
**Date:** 2026-05-04

<!--toc:start-->
- [Decisions](#decisions)
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Backing Services](#backing-services)
  - [Postgres Backend Modes](#postgres-backend-modes)
  - [Valkey Backend Modes](#valkey-backend-modes)
  - [ClickHouse and S3 (external-only)](#clickhouse-and-s3-external-only)
  - [Web and Worker Deployments](#web-and-worker-deployments)
  - [Ingress and Gateway API](#ingress-and-gateway-api)
  - [Secret Strategy](#secret-strategy)
- [API / Interface Changes](#api--interface-changes)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Chart name? | `langfuse` (matches upstream package + repo `fleetdm` convention). |
| 2 | Postgres modes — include `cnpg`? | Yes — `baked` (default), `cnpg`, `external`. |
| 3 | Valkey baked persistence default? | `enabled: false`. Queue + cache, ephemeral is OK for v0.1; user can flip on. |
| 4 | Default Postgres image? | `postgres:16`. |
| 5 | Default Valkey image? | `valkey/valkey:9.0.3` (latest major, matches fleetdm). |
| 6 | Auth Secret strategy? | Single `langfuse.auth.existingSecret` with multiple keys (`nextauth-secret`, `encryption-key`, `salt`). License Secret separate (EE-only). |
| 7 | Ingress vs HTTPRoute default? | `langfuse.ingress.enabled: true`, `langfuse.httpRoute.enabled: false`. |
| 8 | `web`/`worker` env override shape? | List, matching the standard K8s `envVar` shape. |
| 9 | Initial `Chart.version`? | `0.1.0`. |
| 10 | Initial `appVersion`? | `3.172.1`. |
| 11 | Render a ClickHouse Operator `Cluster` example in `examples/` (not `templates/`)? | Yes. Documented, not chart-rendered. |
| 12 | helm-test connectivity hooks (Postgres / Valkey / Langfuse `/api/public/health`)? | Yes — same shape as fleetdm. |
| 13 | License? | MIT. |

**Architectural confirmations:**

- ClickHouse and S3 are **external-only** — chart never renders them.
- Application secrets (`NEXTAUTH_SECRET`, `ENCRYPTION_KEY`, `SALT`,
  license key) are **`existingSecret` only** — chart never auto-
  generates, helper fails closed (per [INV-0001][inv-0001]).
- **No KEDA, HPA, VPA, PDB** in v0.1. Just `replicaCount` on web and
  worker (with `langfuse.replicas` as the inherited default).

## Overview

Build a slim, opinionated Helm chart for Langfuse v3 that drops the upstream
chart's heavy dependency surface — no Bitnami sub-charts, no bundled
ClickHouse — and exposes a small set of deployment shapes via a
backend-modes pattern (mirroring the repo-guardian chart) so users can run
Langfuse with batteries-included infra in dev or wire it to managed
services (CNPG, RDS, ElastiCache, ClickHouse Operator, S3) in prod.

## Goals and Non-Goals

### Goals

- Run Langfuse v3 (web + worker) in a Kubernetes cluster with a single
  `helm install` and sane defaults.
- Eliminate Bitnami sub-chart dependencies. Replace the bundled
  `postgresql`, `redis`, `clickhouse`, `s3 (MinIO)`, and `common`
  Bitnami sub-charts with first-party templates or external references.
- Offer multiple deployment modes for Postgres and Valkey via a single
  `*.mode` value, similar to repo-guardian's `Store` / `Queue`
  selection.
- Treat **ClickHouse** and **S3 / blob storage** as external inputs only.
  The chart consumes connection details (host/port/credentials,
  bucket/region/credentials) but does **not** render ClickHouse or
  MinIO templates.
- Default to classic `Ingress`, but support **Gateway API `HTTPRoute`**
  (vanilla, compatible with the Cilium Gateway and the AWS Load Balancer
  Controller Gateway implementations).
- Honor the same Helm-secret discipline as the fleetdm chart per
  [INV-0001][inv-0001]: never use `lookup → randAlphaNum` for secret
  generation; require `existingSecret` for sensitive values that survive
  upgrades.
- Support a `replicas` knob on web and worker, with `replicaCount: 1`
  default.

### Non-Goals

- **No KEDA, HPA, or VPA** in v0.1. Replicas only.
- **No PodDisruptionBudget** in v0.1.
- **No bundled ClickHouse**. The chart does not deploy ClickHouse and does
  not render `Cluster` CRs for the ClickHouse Operator. Users either
  bring their own (Operator-managed, cloud-hosted) or run a
  `clickhouse-operator` `Cluster` CR out-of-band.
- **No bundled MinIO / object storage**. The chart consumes S3 connection
  values; it does not deploy storage.
- **No memory / no-dep mode** for Postgres or Valkey. Langfuse v3 hard-
  requires both — a memory-only mode would not run.
- **No upstream chart compatibility shim**. This is a fresh chart with
  its own values shape; we are not trying to be a drop-in replacement
  for `langfuse/langfuse-k8s`.

## Background

Langfuse v3 is the [self-hosted version][langfuse-v3] of the open-source
Langfuse observability platform. Its architecture (per the upstream
[infrastructure docs][langfuse-infra]) hard-requires four backing
services:

| Service | Purpose | Required? |
|---|---|---|
| Postgres | Transactional data (users, orgs, projects, API keys) | Yes |
| Redis / Valkey | Queue (event ingestion) + cache | Yes |
| ClickHouse | OLAP storage for traces, observations, scores | Yes |
| S3 / blob storage | Raw event persistence; optional media uploads | Yes |

The [upstream Helm chart][upstream-chart] bundles all four as Bitnami
sub-charts. For our use, that is too much surface area: we already run
ClickHouse via the [ClickHouse Operator][ch-operator] and S3-compatible
storage out-of-band. The Bitnami coupling also forces a vendor
dependency we do not want.

The repo-guardian chart's [Backend Modes pattern][rg-modes] solves the
same problem for a different application: instead of unconditionally
deploying a sub-chart, it picks one of N implementations of a backing
service via `*.mode` values, rendering different resources per mode.
This chart adopts the same pattern for Postgres and Valkey.

## Detailed Design

### Backing Services

| Service | Chart-deployed by default? | Modes available | Notes |
|---|---|---|---|
| Postgres | Yes | `baked`, `cnpg`, `external` | Required by Langfuse |
| Valkey | Yes | `baked`, `external` | Required for queue + cache |
| ClickHouse | **No** | `external` only | User runs ClickHouse Operator or has cloud-managed ClickHouse |
| S3 | **No** | `external` only | User provides bucket + credentials |

### Postgres Backend Modes

Mirrors repo-guardian. Selected via `postgres.mode`:

| Mode | Resources rendered | Use case |
|---|---|---|
| **`baked`** *(default)* | `Deployment` + `Service` + `PVC` + `Secret` | Dev / homelab |
| **`cnpg`** | CloudNativePG `Cluster` CR | Production with CNPG operator pre-installed |
| **`external`** | None — values reference an existing host + Secret | RDS, Cloud SQL, etc. |

CNPG mode requires the CNPG operator pre-installed cluster-wide; the
chart renders a `Cluster` CR but takes no Helm sub-chart dependency on
the operator (matches repo-guardian and server-price-tracker
patterns). CNPG creates a `<cluster>-app` Secret with `host`,
`username`, `password`, `dbname` keys; the Langfuse Deployment consumes
those via `secretKeyRef`.

External mode requires `postgres.external.host`, `.port`, `.database`,
`.user`, and `postgres.external.existingSecret` containing
the password under `postgres.external.passwordKey`.

### Valkey Backend Modes

Selected via `valkey.mode`:

| Mode | Resources rendered | Use case |
|---|---|---|
| **`baked`** *(default)* | `Deployment` + `Service` + `PVC` (optional) + Secret-existing-required if password auth | Dev / homelab |
| **`external`** | None — values reference an existing host + Secret | ElastiCache, Redis Cloud, etc. |

External mode requires `valkey.external.host`, `.port`, and
`valkey.external.existingSecret`.

Following INV-0001: the chart never auto-generates the Valkey password.
When password auth is enabled (default), `existingSecret` is required
in both modes; the helper fails closed with an actionable error.

### ClickHouse and S3 (external-only)

Both are inputs to the chart, not outputs. Values shape:

```yaml
clickhouse:
  url: "http://clickhouse.clickhouse.svc.cluster.local:8123"
  migrationUrl: "clickhouse://clickhouse.clickhouse.svc.cluster.local:9000"
  user: default
  existingSecret: langfuse-clickhouse-credentials
  passwordKey: clickhouse-password

s3:
  endpoint: "https://s3.us-east-1.amazonaws.com"
  region: us-east-1
  bucket: langfuse-events
  forcePathStyle: false
  existingSecret: langfuse-s3-credentials
  accessKeyIdKey: access-key-id
  secretAccessKeyKey: secret-access-key
```

The `*-secret.yaml` template never renders for these — Secrets are
provisioned out-of-band. Helpers fail closed if either the URL or the
existingSecret is missing.

### Web and Worker Deployments

Two separate Deployments mirroring the upstream split:

- **`langfuse-web`** — listens on port 3000, serves the API + UI.
  Liveness `/api/public/health`, readiness `/api/public/ready`.
- **`langfuse-worker`** — listens on port 3030, processes the event
  queue. Liveness `/api/health`.

Inheritance: `langfuse.*` defines pod-level defaults (`replicas`,
`image`, `resources`, `nodeSelector`, `tolerations`, `affinity`,
security contexts, pod annotations/labels). `langfuse.web.*` and
`langfuse.worker.*` override those per-deployment. A helper merges the
two so per-component values win when set, otherwise the langfuse-level
default applies.

Env wiring: a `langfuse.commonEnv` helper assembles the env block every
Langfuse pod needs (DATABASE_URL pieces, REDIS_*, CLICKHOUSE_*, S3_*,
NEXTAUTH_*, ENCRYPTION_KEY, SALT, NODE_ENV, LOG_LEVEL, etc.) by
referencing values + Secret keys via `secretKeyRef`. Per-component
extras (`langfuse.web.additionalEnv`, `langfuse.worker.additionalEnv`)
append on top, plus the chart-wide `langfuse.additionalEnv` /
`additionalEnvFrom` apply to both.

A single `Service` (ClusterIP) fronts `langfuse-web` and is the only
entrypoint exposed externally; `langfuse-worker` has no `Service`.

### Ingress and Gateway API

Both live under `langfuse.*` since they front the langfuse-web Service.
Three mutually-relevant access shapes:

| Values | Resources rendered |
|---|---|
| `langfuse.ingress.enabled: true` *(default)* | `Ingress` (classic) |
| `langfuse.httpRoute.enabled: true` | Gateway API `HTTPRoute` (guarded on non-empty `parentRefs`, matching the fleetdm chart's safe-default pattern) |
| neither | only the in-cluster `Service` |

The `HTTPRoute` template emits **vanilla Gateway API**. Cilium's Gateway
implementation and the AWS Load Balancer Controller's Gateway
implementation both accept vanilla `HTTPRoute` resources. Per-flavor
annotations / parentRef shapes are pushed up to the user via
`langfuse.httpRoute.annotations` and `langfuse.httpRoute.parentRefs`.

cert-manager `Certificate` rendering for the `HTTPRoute` TLS path
follows the fleetdm pattern (`langfuse.httpRoute.certManager.enabled`,
`clusterIssuer`, `certificateName`).

### Secret Strategy

Per [INV-0001][inv-0001]:

- **Auth/encryption secrets** (`NEXTAUTH_SECRET`, `ENCRYPTION_KEY`,
  `SALT`, `LICENSE_KEY`): chart **never** generates. `existingSecret`
  required. Helper fails closed with actionable error.
- **Postgres baked-mode Secret**: chart-managed (mirroring fleetdm's
  current MySQL pattern with `lookup`+`randAlphaNum` +
  `helm.sh/resource-policy: keep`). Overridable via
  `postgres.baked.existingSecret`. Vulnerable to the same `helm
  template`-render regeneration noted in INV-0001 — accept the same
  trade-off as fleetdm and track in [issue #17][issue-17].
- **Postgres CNPG-mode Secret**: managed by CNPG, not the chart.
- **Valkey Secret**: chart **never** generates (whether mode is `baked`
  or `external`). `existingSecret` required when password auth is on.
- **ClickHouse Secret, S3 Secret**: chart **never** generates.

## API / Interface Changes

This is a new chart, not a change to an existing one. Values shape
mirrors the upstream chart's organization: everything app-shaped lives
under `langfuse:` (so it's easy to extend with future Langfuse-specific
config like SSO providers, SMTP, etc.); only true infra inputs sit at
the top level.

```yaml
nameOverride: ""
fullnameOverride: ""

# Everything langfuse-app-shaped lives under here.
langfuse:
  # Pod-level defaults inherited by web and worker (each can override).
  replicas: 1
  revisionHistoryLimit: 10
  resources: {}
  image:
    # Tag falls back to appVersion when null.
    tag: null
    pullPolicy: IfNotPresent
    pullSecrets: []
  podSecurityContext: {}
  securityContext: {}
  nodeSelector: {}
  tolerations: []
  affinity: {}
  dnsConfig: {}
  pod:
    annotations: {}
    labels: {}
    topologySpreadConstraints: []
  deployment:
    annotations: {}
    strategy: {}
  serviceAccount:
    create: true
    annotations: {}
    name: ""
    automountServiceAccountToken: true

  # Application config.
  nodeEnv: production
  logging:
    level: info       # trace | debug | info | warn | error | fatal
    format: text      # text | json
  features:
    telemetryEnabled: true
    signUpDisabled: false
    experimentalFeaturesEnabled: false
  auth:
    disableUsernamePassword: false
    providers: {}
    # Application secrets (NEXTAUTH_SECRET, ENCRYPTION_KEY, SALT) —
    # existingSecret only; chart never auto-generates (INV-0001).
    existingSecret: ""
    nextauthSecretKey: nextauth-secret
    encryptionKeyKey: encryption-key
    saltKey: salt
  license:
    # Optional, EE features.
    existingSecret: ""
    licenseKeyKey: license-key
  smtp:
    connectionUrl: ""
    fromAddress: ""

  # Per-deployment overrides. Each inherits from langfuse.* defaults
  # above and overrides only what's set.
  web:
    image:
      repository: langfuse/langfuse
    replicas: 1
    service:
      type: ClusterIP
      port: 3000
    additionalEnv: []
    additionalEnvFrom: []
    extraContainers: []
    extraVolumes: []
    extraVolumeMounts: []
    extraInitContainers: []
    extraLifecycle: {}
  worker:
    image:
      repository: langfuse/langfuse-worker
    replicas: 1
    additionalEnv: []
    additionalEnvFrom: []
    extraContainers: []
    extraVolumes: []
    extraVolumeMounts: []
    extraInitContainers: []
    extraLifecycle: {}

  # Ingress for the langfuse-web Service.
  ingress:
    enabled: true
    className: ""
    annotations: {}
    hosts: []
    tls: []

  # Gateway API HTTPRoute for the langfuse-web Service. Vanilla
  # HTTPRoute, compatible with Cilium Gateway and AWS LB Controller
  # Gateway implementations. Guarded on non-empty parentRefs.
  httpRoute:
    enabled: false
    hostname: ""
    parentRefs: []
    annotations: {}
    certManager:
      enabled: false
      clusterIssuer: ""
      certificateName: ""

  # Shared additional env / envFrom applied to BOTH web and worker.
  additionalEnv: []
  additionalEnvFrom: []
  extraContainers: []
  extraVolumes: []
  extraVolumeMounts: []
  extraInitContainers: []
  extraLifecycle: {}

# Backing services live at the top level — they are infra inputs, not
# part of the langfuse application surface.

postgres:
  mode: baked                  # baked | cnpg | external
  baked:
    image:
      repository: postgres
      tag: "16"
    persistence:
      enabled: true
      size: 10Gi
    existingSecret: ""         # optional override
  cnpg:
    clusterName: ""            # required when mode=cnpg
    appSecretName: ""          # defaults to <clusterName>-app
  external:
    host: ""
    port: 5432
    database: langfuse
    user: langfuse
    existingSecret: ""         # required
    passwordKey: postgres-password

valkey:
  mode: baked                  # baked | external
  usePassword: true
  baked:
    image:
      repository: valkey/valkey
      tag: "8"
    persistence:
      enabled: false
      size: 1Gi
    existingSecret: ""         # required when usePassword=true
  external:
    host: ""
    port: 6379
    existingSecret: ""         # required when usePassword=true
    passwordKey: valkey-password

clickhouse:
  url: ""                      # required
  migrationUrl: ""             # required
  user: default
  existingSecret: ""           # required
  passwordKey: clickhouse-password

s3:
  endpoint: ""                 # required
  region: ""
  bucket: ""                   # required
  forcePathStyle: false
  existingSecret: ""           # required
  accessKeyIdKey: access-key-id
  secretAccessKeyKey: secret-access-key
```

## Testing Strategy

Match the fleetdm chart's test discipline:

- **`helm-unittest`** suites for: web deployment, worker deployment, web
  service, ingress, httproute, postgres-baked, postgres-cnpg, valkey,
  secret-rendering (the few we render), helpers (mode validation,
  existingSecret fail-closed paths).
- **`ct lint`** on at least two CI values files:
  - `ci/default-values.yaml` — `postgres.mode=baked`,
    `valkey.mode=baked`, all required existingSecrets stubbed via
    pre-rendered Secrets in CI fixtures.
  - `ci/external-values.yaml` — `postgres.mode=external`,
    `valkey.mode=external`, all infra inputs stubbed.
  - Maybe `ci/cnpg-values.yaml` — `postgres.mode=cnpg`. (CRDs missing in
    CI is fine; `ct lint` doesn't apply.)
- **`ct install`** in Kind: only feasible for the `baked` modes (no
  CNPG operator, no real ClickHouse, no real S3 in Kind). Could mock
  ClickHouse and S3 with stub Deployments in a CI-only values overlay
  if we want a green install path; deferred until v0.2.
- **`make helm-docs-check`** — README must stay in sync.

## Migration / Rollout Plan

Net-new chart. No migration. First release: `0.1.0` with `appVersion`
pinned to a current Langfuse v3 release (TBD in IMPL).

Renovate annotation on `appVersion` per the repo convention:
```yaml
# renovate: image=langfuse/langfuse
appVersion: "3.x.y"
```

## Open Questions

None remaining. All resolved in the [Decisions](#decisions) table.

## References

- [Upstream Langfuse k8s chart][upstream-chart]
- [Langfuse v3 self-hosting infrastructure docs][langfuse-infra]
- [Langfuse v3 release notes][langfuse-v3]
- [ClickHouse Operator][ch-operator]
- [repo-guardian backend-modes pattern][rg-modes]
- [INV-0001 — fleetdm secret regeneration under helm template][inv-0001]
- [Issue #17 — adopt idiomatic Helm secret pattern][issue-17]

[upstream-chart]: https://github.com/langfuse/langfuse-k8s/tree/main/charts/langfuse
[langfuse-infra]: https://langfuse.com/self-hosting/infrastructure
[langfuse-v3]: https://langfuse.com/self-hosting/v3
[ch-operator]: https://github.com/ClickHouse/clickhouse-operator
[rg-modes]: https://github.com/donaldgifford/repo-guardian/blob/docs/design-persistent-reconcile-state/docs/design/0012-persistent-reconcile-state-and-multi-replica-coordination.md#backend-modes-and-chart-deployment-shapes
[inv-0001]: ../investigation/0001-fleetdm-secret-regeneration-under-helm-template.md
[issue-17]: https://github.com/donaldgifford/helm-charts/issues/17
