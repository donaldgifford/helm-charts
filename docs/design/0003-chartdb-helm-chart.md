---
id: DESIGN-0003
title: "ChartDB Helm chart"
status: Accepted
author: Donald Gifford
created: 2026-05-24
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0003: ChartDB Helm chart

**Status:** Accepted
**Author:** Donald Gifford
**Date:** 2026-05-24

<!--toc:start-->
- [Decisions](#decisions)
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Deployment Shape](#deployment-shape)
  - [Configuration Surface](#configuration-surface)
  - [Security Context](#security-context)
  - [Ingress and Gateway API](#ingress-and-gateway-api)
  - [Secret Strategy](#secret-strategy)
- [API / Interface Changes](#api--interface-changes)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Future Considerations](#future-considerations)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Container port + non-root strategy | Use the upstream image as-is. nginx listens on hardcoded `:80`; we **do not** ship a custom `nginx.conf` ConfigMap (upstream already templates `default.conf.template` via envsubst). Container runs as `runAsUser: 101` (nginx user) with `capabilities.add: [NET_BIND_SERVICE]` to allow binding `:80` while staying non-root. Service is `port: 80, targetPort: 80`. |
| 2 | Chart name? | `chartdb`. |
| 3 | `readOnlyRootFilesystem: true`? | Yes — with `emptyDir` mounts over the paths the upstream entrypoint and nginx need to write to (`/etc/nginx/conf.d/`, `/var/cache/nginx/`, `/var/run/`, `/tmp/`). Validated in IMPL Phase 1; if a mount path is missed, fall back to `false` and track follow-up. |
| 4 | `OPENAI_API_KEY` strategy? | `existingSecret`-only — per [INV-0001][inv-0001] precedent. Helper fails closed when `chartdb.openai.enabled: true` without an `existingSecret`. |
| 5 | HPA / autoscaling in v0.1? | No. `replicaCount` only. ChartDB is stateless; HPA is trivial to add later. |
| 6 | Initial `appVersion`? | `1.20.1`. |
| 7 | Initial `Chart.version`? | `0.1.0`. |
| 8 | `automountServiceAccountToken` default? | `false`. ChartDB has no need for the API server token; reduces attack surface. |
| 9 | Resource defaults? | `requests: { cpu: 10m, memory: 32Mi }`, `limits: { memory: 128Mi }`. No CPU limit. |
| 10 | helm-test included in v0.1? | Yes — single curl-against-Service hook. Same Trivy-pod-security shape as the fleetdm test hooks. |
| 11 | License? | MIT — matches repo. |
| 12 | NetworkPolicy in v0.1? | No. Deferred. |

## Overview

A minimal Helm chart for [ChartDB][chartdb], an open-source
browser-based database diagram editor. ChartDB is a stateless
single-container web app (nginx + static SPA assets), so the chart is
correspondingly thin: one Deployment, one Service, an optional
Ingress, an optional Gateway API HTTPRoute, and optional configuration
for ChartDB's runtime-injected env vars (notably the OpenAI / LLM
endpoint for the AI features).

## Goals and Non-Goals

### Goals

- Run ChartDB in a Kubernetes cluster with `helm install` and a
  single host value.
- Mirror the access-path conventions used by the `fleetdm` and
  `langfuse` charts in this repo: default-on `Ingress`, default-off
  Gateway API `HTTPRoute` (vanilla, Cilium- and AWS-LB-Controller-
  compatible), optional cert-manager `Certificate` for the HTTPRoute
  TLS path.
- Support ChartDB's runtime env vars
  (`OPENAI_API_KEY`, `OPENAI_API_ENDPOINT`, `LLM_MODEL_NAME`,
  `HIDE_CHARTDB_CLOUD`, `DISABLE_ANALYTICS`) via values; sensitive
  values (`OPENAI_API_KEY`) only via `existingSecret` per
  [INV-0001][inv-0001].
- Sane production defaults: `readOnlyRootFilesystem`,
  `runAsNonRoot`, non-root nginx port, resource requests/limits,
  liveness/readiness probes on `/`.
- Horizontal scaling via `replicaCount` (ChartDB is genuinely
  stateless, so this works trivially), default `1`.

### Non-Goals

- **No backing services.** ChartDB has zero server-side state —
  no Postgres, Redis, ClickHouse, S3, or local PVC. The chart
  renders none of these.
- **No HPA, KEDA, VPA, PDB** in v0.1. Replicas only. (Matches the
  rest of the repo's v0.1 charts; the chart is stateless so HPA is
  a trivial later add.)
- **No backend-modes pattern.** Nothing to deploy in modes — there
  are no backing services. The "mode" knobs from the langfuse chart
  do not apply.
- **No worker process.** ChartDB has no background jobs.
- **No build-time env vars.** The upstream image supports both
  build-time (`VITE_*`) and runtime (`OPENAI_API_KEY`, etc.) env
  vars. We expose only the runtime ones — users who want a custom
  build can fork the image, not the chart.
- **No PWA / asset-cache customization** in v0.1.

## Background

ChartDB is published as a single multi-arch image at
`ghcr.io/chartdb/chartdb:<tag>`. It's an nginx-served React SPA: the
browser does all the work, including direct database connections to
the user's database. There is no backend, no database, no cache, and
no persistent storage. The image's entrypoint runs `envsubst` to
templating a `/config.js` file from the runtime env vars; the browser
then loads that file at startup.

The upstream project does **not** publish a Helm chart and provides no
documented Kubernetes deployment path beyond the Docker image itself.
That's the gap this chart fills.

Compared to the other charts in this repo:

| Chart | Backing services | Secrets we manage | Templates rendered |
|---|---|---|---|
| `fleetdm` | embedded MySQL, optional Valkey | MySQL (chart-managed), cache (existingSecret-only) | ~10 |
| `langfuse` *(DESIGN-0003, separate branch)* | embedded Postgres + Valkey or external; ClickHouse + S3 external-only | postgres-baked (chart-managed), all others existingSecret-only | ~15 |
| **`chartdb` *(this design)*** | none | none by default; `OPENAI_API_KEY` existingSecret only when set | ~5 |

This is roughly the simplest non-trivial chart this repo will host.

## Detailed Design

### Deployment Shape

Single Kubernetes Deployment + ClusterIP Service. No StatefulSet, no
PVC, no init containers.

| Resource | Count | Notes |
|---|---|---|
| `Deployment` | 1 | `ghcr.io/chartdb/chartdb` image, port 8080 |
| `Service` | 1 | ClusterIP, `port: 80`, `targetPort: 8080` |
| `ServiceAccount` | optional | `serviceAccount.create: true` by default |
| `Ingress` | optional | `ingress.enabled: true` by default |
| `HTTPRoute` | optional | `httpRoute.enabled: false` by default; guarded on non-empty `parentRefs` |
| `Certificate` (cert-manager) | optional | only when `httpRoute.certManager.enabled: true` |
| `Pod` (`helm.sh/hook: test`) | optional | helm-test smoke check |

The chart picks `targetPort: 8080` (not 80) so the container can
run as non-root without `CAP_NET_BIND_SERVICE`. The upstream image
listens on 80 by default; we'll override via `PORT` env or
`nginx.conf` injection — see [Open Questions §1](#open-questions).

### Configuration Surface

All exposed through `chartdb.*` values for app-shaped settings (env
vars, image, replicas, ingress, httpRoute, security context) and
nothing else at top level except `nameOverride` / `fullnameOverride`.
This mirrors the langfuse chart's "everything under one app key"
shape per user direction, though here there is no `web` / `worker`
split — only the single Deployment.

Runtime env vars that ChartDB consumes:

| Env var | Purpose | How chart exposes it |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI / LLM API key for the AI SQL features | `chartdb.openai.existingSecret` + `apiKeyKey` (sensitive — secret only) |
| `OPENAI_API_ENDPOINT` | Custom LLM endpoint (e.g., for Azure OpenAI, local LLMs) | `chartdb.openai.endpoint` (literal value) |
| `LLM_MODEL_NAME` | Model name for inference | `chartdb.openai.model` (literal value) |
| `HIDE_CHARTDB_CLOUD` | Hide cloud signup/login UI | `chartdb.ui.hideChartdbCloud` (bool) |
| `DISABLE_ANALYTICS` | Disable Fathom analytics | `chartdb.ui.disableAnalytics` (bool) |

Plus the standard extensibility hooks (matching the langfuse chart):
`additionalEnv`, `additionalEnvFrom`, `extraContainers`,
`extraVolumes`, `extraVolumeMounts`, `extraInitContainers`,
`extraLifecycle`.

### Security Context

ChartDB's image is `nginx:stable-alpine` + static assets + a custom
entrypoint. nginx listens on hardcoded `:80` (the upstream
[`default.conf.template`][upstream-conf] does not parameterize the
listen port), and the entrypoint runs `envsubst` against the template
to produce `/etc/nginx/conf.d/default.conf` at container start.

To stay non-root while still binding `:80`, the chart sets
`runAsUser: 101` (the `nginx` user in alpine images) and adds the
`NET_BIND_SERVICE` Linux capability. This avoids the alternative of
running as root or shipping our own nginx config to override the
listen port (which would diverge from upstream and break on every
ChartDB release that updates `default.conf.template`).

`readOnlyRootFilesystem: true` requires `emptyDir` mounts over the
paths the upstream's entrypoint and nginx need to write to (at
minimum: `/etc/nginx/conf.d/` for the rendered config, `/var/cache/nginx/`,
`/var/run/`, `/tmp/`). Exact list confirmed during IMPL Phase 1.

Defaults:

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 101         # nginx user in the upstream image
  runAsGroup: 101
  fsGroup: 101
  seccompProfile:
    type: RuntimeDefault
securityContext:
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]
```

### Ingress and Gateway API

Same three-way shape as fleetdm and langfuse:

| Values | Resources rendered |
|---|---|
| `chartdb.ingress.enabled: true` *(default)* | classic `Ingress` |
| `chartdb.httpRoute.enabled: true` AND non-empty `parentRefs` | vanilla Gateway API `HTTPRoute` |
| neither | only the in-cluster `Service` |

Both render under `chartdb.*` since they front the chartdb Service.
The `HTTPRoute` template emits vanilla `gateway.networking.k8s.io/v1`,
compatible with the Cilium Gateway and AWS Load Balancer Controller
Gateway implementations.

### Secret Strategy

Per [INV-0001][inv-0001] and the conventions established by the
fleetdm and langfuse charts:

- **The chart never auto-generates Secrets.** ChartDB has no chart-
  managed credentials at all.
- **`OPENAI_API_KEY`** is sensitive. If a user wants AI features,
  they must provide `chartdb.openai.existingSecret`. The chart's
  helper fails closed with an actionable message when AI features
  are enabled but no Secret name is set.
- **`OPENAI_API_ENDPOINT` / `LLM_MODEL_NAME` / `HIDE_CHARTDB_CLOUD` /
  `DISABLE_ANALYTICS`** are literal-value values in the chart — not
  sensitive.

## API / Interface Changes

This is a new chart. Sketched values shape:

```yaml
nameOverride: ""
fullnameOverride: ""

chartdb:
  image:
    repository: ghcr.io/chartdb/chartdb
    tag: ""              # falls back to appVersion
    pullPolicy: IfNotPresent
    pullSecrets: []

  replicaCount: 1
  revisionHistoryLimit: 1

  service:
    type: ClusterIP
    port: 80
    targetPort: 80

  serviceAccount:
    create: true
    annotations: {}
    name: ""
    automountServiceAccountToken: false

  # Pod-level
  podAnnotations: {}
  podLabels: {}
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    fsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  securityContext:
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
      add: [NET_BIND_SERVICE]   # allows nginx to bind :80 as non-root uid 101
  nodeSelector: {}
  tolerations: []
  affinity: {}
  topologySpreadConstraints: []

  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 128Mi

  livenessProbe:
    httpGet:
      path: /
      port: http
    initialDelaySeconds: 5
    periodSeconds: 10
  readinessProbe:
    httpGet:
      path: /
      port: http
    initialDelaySeconds: 2
    periodSeconds: 5

  # Application config — runtime env vars consumed by the upstream
  # image's envsubst entrypoint.
  openai:
    enabled: false
    existingSecret: ""        # required when enabled=true
    apiKeyKey: openai-api-key
    endpoint: ""              # literal value, optional
    model: ""                 # literal value, optional
  ui:
    hideChartdbCloud: false
    disableAnalytics: false

  # Extensibility (matches langfuse chart)
  additionalEnv: []
  additionalEnvFrom: []
  extraContainers: []
  extraVolumes: []
  extraVolumeMounts: []
  extraInitContainers: []
  extraLifecycle: {}

  ingress:
    enabled: true
    className: ""
    annotations: {}
    hosts: []
    tls: []

  httpRoute:
    enabled: false
    hostname: ""
    parentRefs: []
    annotations: {}
    certManager:
      enabled: false
      clusterIssuer: ""
      certificateName: ""
```

## Testing Strategy

- **`helm-unittest`** — modest suites:
  - deployment (image, port, env wiring, security context,
    readOnlyRootFilesystem emptyDir, probes, replicas)
  - service (ports, selector)
  - ingress (renders only when enabled; hosts/paths pass through)
  - httproute (renders only when enabled AND parentRefs non-empty;
    vanilla GW API)
  - certificate (renders only when cert-manager block enabled)
  - serviceaccount (renders only when create=true)
  - helpers (openai existingSecret fail-closed when enabled)

  Target: 6–8 suites, ~30–40 tests.

- **`ct lint`** — two CI values files:
  - `ci/default-values.yaml` — defaults plus a stub `Ingress` host.
  - `ci/openai-values.yaml` — `openai.enabled: true` with
    `existingSecret: chartdb-openai-stub` to exercise the env
    wiring.

- **`ct install`** — feasible in Kind for this chart. No backing
  services, no CRDs required for the default path. Default values
  file should install cleanly into Kind and pass a basic curl
  against the Service.

- **helm-test** — a single connectivity hook: `curl -fsS
  http://<release>-chartdb:80/` returns 200 (the SPA's index.html).

- **`make helm-docs-check`** — README must stay in sync.

## Migration / Rollout Plan

Net-new chart. No migration. First release: `0.1.0`, `appVersion:
1.20.1`.

Renovate annotation per the repo convention:

```yaml
# renovate: image=ghcr.io/chartdb/chartdb
appVersion: "1.20.1"
```

## Future Considerations

- **Drop `NET_BIND_SERVICE` via an init container** *(v0.2 candidate)*.
  An init container could `sed` upstream's `default.conf.template` to
  rewrite `listen 80` → `listen 8080` and write the modified template
  to a shared `emptyDir` that the main container mounts over
  `/etc/nginx/conf.d/`. The main container would then run with
  `targetPort: 8080` and drop the `NET_BIND_SERVICE` capability
  entirely; Service stays `port: 80`, `targetPort: 8080`. Trade-off:
  the chart would couple to upstream's template layout and every
  ChartDB release that touches `default.conf.template` becomes a
  potential break. Justified only if a consumer hits a cluster policy
  (OPA/Kyverno) that forbids capability additions including
  `NET_BIND_SERVICE`. Until then, `NET_BIND_SERVICE` is fully PSS-
  Restricted-compliant and is the cleaner default.
- **HPA / autoscaling**. ChartDB is genuinely stateless, so a basic
  CPU-target HPA is a trivial later add. Deferred from v0.1 to match
  the rest of the repo.

## Open Questions

None remaining. All resolved in the [Decisions](#decisions) table.

## References

- [ChartDB GitHub repository][chartdb]
- [ChartDB docs (docs.chartdb.io)](https://docs.chartdb.io)
- [ChartDB website (chartdb.io)](https://www.chartdb.io)
- [DESIGN-0001 — fleetdm Helm chart](./0001-fleetdm-helm-chart.md)
- [INV-0001 — fleetdm secret regeneration under helm template][inv-0001]

[chartdb]: https://github.com/chartdb/chartdb
[upstream-conf]: https://github.com/chartdb/chartdb/blob/main/default.conf.template
[inv-0001]: ../investigation/0001-fleetdm-secret-regeneration-under-helm-template.md
