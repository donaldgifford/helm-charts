---
id: IMPL-0004
title: "Build langfuse helm chart v0.1.0"
status: InProgress
author: Donald Gifford
created: 2026-05-04
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0004: Build langfuse helm chart v0.1.0

**Status:** InProgress
**Author:** Donald Gifford
**Date:** 2026-05-04

<!--toc:start-->
- [Decisions](#decisions)
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Chart scaffold](#phase-1-chart-scaffold)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Helpers and Secret strategy](#phase-2-helpers-and-secret-strategy)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Backing services (Postgres + Valkey)](#phase-3-backing-services-postgres--valkey)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Web and Worker Deployments](#phase-4-web-and-worker-deployments)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Ingress and Gateway API](#phase-5-ingress-and-gateway-api)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: helm-test, examples, and docs](#phase-6-helm-test-examples-and-docs)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: CI integration and PR](#phase-7-ci-integration-and-pr)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | langfuse-web Service port: `port=3000` (target 3000) or `port=80` (target 3000)? | `port=3000`. Matches container port, simpler. Users front with 80 via Ingress / Gateway. |
| 2 | Postgres baked: StatefulSet vs Deployment? | StatefulSet — stable PVC binding, matches fleetdm's MySQL pattern. |
| 3 | Valkey baked shape? | Always StatefulSet (regardless of `persistence.enabled`). Avoids conditional template branching; matches fleetdm Valkey. |
| 4 | ClickHouse credential wiring: `CLICKHOUSE_URL` with embedded creds, or separate `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` env? | Both envs separately. URL stays creds-free, USER/PASSWORD via `secretKeyRef`. |
| 5 | `revisionHistoryLimit` default? | `1`. Matches fleetdm + repo convention; user can override. |
| 6 | Postgres baked: init container to create DB, or rely on `POSTGRES_DB` env? | Rely on `POSTGRES_DB` env. No init container. |
| 7 | helm-test pods opt out per backing-service mode? | Yes. `test-postgres.yaml` only renders in `baked` or `cnpg` mode; `test-valkey.yaml` only in `baked`. |
| 8 | Single shared ServiceAccount for web + worker, or split? | Single, shared. Matches upstream. RBAC split deferred. |
| 9 | Naming for chart-deployed resources? | `<release>-postgres`, `<release>-valkey`. E.g. `langfuse-postgres-0` for the StatefulSet pod. |
| 10 | `ct install` skip mechanism? | `ct.yaml excludeCharts: [langfuse]`. Lever in code, not CI YAML. |
| 11 | Per-chart `LICENSE` file inside `charts/langfuse/`? | No. Repo-root LICENSE only. Matches fleetdm. |
| 12 | Postgres baked PVC default size? | `10Gi`. Matches fleetdm MySQL default. |

## Objective

Build the first release (`0.1.0`) of a slim, opinionated `langfuse`
Helm chart per [DESIGN-0003][design-0003]. The chart deploys
Langfuse v3 (web + worker) with chart-managed Postgres and Valkey
defaults, while treating ClickHouse and S3 as external inputs only.

**Implements:** [DESIGN-0003 — Langfuse Helm chart][design-0003]

## Scope

### In Scope

- New chart at `charts/langfuse/` with `Chart.yaml`, `values.yaml`,
  `values.schema.json`, `templates/`, `tests/`, `ci/`, `examples/`,
  `README.md.gotmpl`, and `.helmignore`.
- Postgres backend modes: `baked` (default), `cnpg`, `external`.
- Valkey backend modes: `baked` (default), `external`.
- ClickHouse and S3: external-only (chart never renders them).
- Web (`langfuse-web`) and Worker (`langfuse-worker`) Deployments
  with inheritance from `langfuse.*` defaults.
- Single `Service` (ClusterIP) fronting `langfuse-web`.
- Classic `Ingress` (default-on) and Gateway API `HTTPRoute`
  (default-off) under `langfuse.ingress.*` and `langfuse.httpRoute.*`.
- Chart-managed Secret for postgres-baked-mode only (Helm
  `lookup`+`randAlphaNum` + `helm.sh/resource-policy: keep`,
  matching the fleetdm chart's MySQL pattern).
- `existingSecret`-only for application secrets
  (`langfuse.auth.existingSecret`, `langfuse.license.existingSecret`),
  Valkey secrets, ClickHouse, and S3 — helpers fail closed when
  missing.
- helm-unittest suites covering each rendered template and each
  mode combination.
- CI values files: `default-values.yaml` (baked + baked),
  `external-values.yaml` (external + external), `cnpg-values.yaml`
  (cnpg + baked).
- helm-test connectivity hooks (Postgres, Valkey, Langfuse
  `/api/public/health`).
- Renovate annotation on `appVersion` (`# renovate:
  image=langfuse/langfuse`).
- `examples/clickhouse-cluster.yaml` — ClickHouse Operator `Cluster`
  CR example, documented but not chart-rendered.

### Out of Scope

- KEDA, HPA, VPA. (Replicas only; deferred.)
- PodDisruptionBudget. (Deferred.)
- ClickHouse template rendering. (External-only.)
- S3 / blob storage template rendering. (External-only.)
- ct install in Kind for this chart in v0.1. ClickHouse and S3 are
  hard requirements of the application; a green `ct install` would
  need stub Deployments for both, which adds CI complexity. We rely
  on `ct lint` + helm-unittest. Tracked as a follow-up.
- Application backwards-compat shims with the upstream chart's
  values shape — this chart is a fresh contract.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met. Commit
after each numbered task with conventional commits scoped to
`chart(langfuse)`.

---

### Phase 1: Chart scaffold

Create the directory layout, the metadata files, and a minimal set
of templates that lints cleanly. Establishes the floor for every
later phase.

#### Tasks

- [ ] Create `charts/langfuse/Chart.yaml` with:
  - `apiVersion: v2`
  - `name: langfuse`
  - `description: A Helm chart for Langfuse v3 — open-source LLM observability with embedded Postgres and Valkey, external ClickHouse and S3`
  - `type: application`
  - `version: 0.1.0`
  - `appVersion: "3.172.1"` with `# renovate: image=langfuse/langfuse` on the line above
  - `home: https://langfuse.com`
  - `sources: [https://github.com/langfuse/langfuse, https://github.com/donaldgifford/helm-charts]`
  - `keywords: [langfuse, llm, observability, tracing, evaluation]`
  - `maintainers: [Donald Gifford]`
  - `dependencies: []`
- [ ] Create `charts/langfuse/.helmignore` (mirror fleetdm).
- [ ] Create `charts/langfuse/values.yaml` matching the shape in
      DESIGN-0003 §API/Interface, with `--` comments for every
      user-facing knob (helm-docs format). Document
      `existingSecret`-required fields explicitly.
- [ ] Create `charts/langfuse/values.schema.json` with at minimum:
  - `postgres.mode`: `enum: ["baked", "cnpg", "external"]`
  - `valkey.mode`: `enum: ["baked", "external"]`
  - `langfuse.logging.level`: `enum: ["trace", "debug", "info", "warn", "error", "fatal"]`
  - `langfuse.logging.format`: `enum: ["text", "json"]`
- [ ] Create `charts/langfuse/templates/_helpers.tpl` with the
      standard Helm name helpers: `langfuse.name`, `langfuse.fullname`,
      `langfuse.chart`, `langfuse.labels`, `langfuse.selectorLabels`,
      and `langfuse.serviceAccountName`.
- [ ] Create `charts/langfuse/templates/serviceaccount.yaml` (renders
      under `langfuse.serviceAccount.create: true`).
- [ ] Create `charts/langfuse/templates/NOTES.txt` placeholder
      (will be expanded in Phase 6).
- [ ] Create `charts/langfuse/README.md.gotmpl` placeholder
      (full content in Phase 6).
- [ ] Run `make helm-docs` to generate `charts/langfuse/README.md`.
- [ ] Run `make helm-lint` and confirm clean.
- [ ] Run `make helm-template` and confirm only the ServiceAccount
      renders for default values.
- [ ] Commit `chart(langfuse): scaffold chart skeleton`.

#### Success Criteria

- `helm lint charts/langfuse` passes with zero errors.
- `helm template charts/langfuse` renders only the ServiceAccount.
- `make helm-docs-check` reports no drift.
- `Chart.yaml` `version: 0.1.0`, `appVersion: 3.172.1`.

---

### Phase 2: Helpers and Secret strategy

Build the helper functions every later template depends on: mode
dispatch, fail-closed paths for existingSecret requirements, and
the postgres-baked Secret rendering. Get this right before wiring
deployments to it.

#### Tasks

- [ ] Extend `_helpers.tpl` with backing-service helpers:
  - `langfuse.postgresHost`, `.postgresPort`, `.postgresDatabase`,
    `.postgresUser` — return the right value per `postgres.mode`,
    `fail` with actionable error if mode is invalid or required
    inputs missing.
  - `langfuse.postgresSecretName`, `.postgresPasswordKey` —
    chart-managed Secret name in `baked` mode; CNPG `<cluster>-app`
    Secret name in `cnpg` mode; user-supplied existingSecret in
    `external` mode (`fail` if missing).
  - `langfuse.valkeyHost`, `.valkeyPort` — value from baked Service
    or external host.
  - `langfuse.valkeySecretName`, `.valkeyPasswordKey` — fail closed
    when `valkey.usePassword: true` and no existingSecret in either
    mode.
  - `langfuse.clickhouseUrl`, `.clickhouseMigrationUrl`,
    `.clickhouseUser`, `.clickhouseSecretName`, `.clickhousePasswordKey`
    — fail closed when URL or existingSecret missing.
  - `langfuse.s3Endpoint`, `.s3Region`, `.s3Bucket`, `.s3SecretName`,
    `.s3AccessKeyIdKey`, `.s3SecretAccessKeyKey` — fail closed when
    bucket or existingSecret missing.
  - `langfuse.authSecretName` — fail closed when
    `langfuse.auth.existingSecret` empty.
- [ ] Add `langfuse.commonEnv` helper that emits the full env
      block referenced by both web and worker Deployments. Uses
      `secretKeyRef` for every credential. Includes:
  - `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`,
    `DATABASE_USERNAME`, `DATABASE_PASSWORD`
  - `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH` (when password auth on)
  - `CLICKHOUSE_URL`, `CLICKHOUSE_MIGRATION_URL`, `CLICKHOUSE_USER`,
    `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_CLUSTER_ENABLED=false`
  - `LANGFUSE_S3_EVENT_UPLOAD_BUCKET`,
    `LANGFUSE_S3_EVENT_UPLOAD_REGION`,
    `LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT`,
    `LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE`,
    `LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID`,
    `LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY`
  - `NEXTAUTH_SECRET`, `ENCRYPTION_KEY`, `SALT`,
    `LANGFUSE_INIT_*` (if used), `LANGFUSE_LOG_LEVEL`,
    `TELEMETRY_ENABLED`, `LANGFUSE_CSP_ENFORCE_HTTPS`, etc.
- [ ] Add `langfuse.podDefaults` helper that merges
      `langfuse.<deployment>.* ` overrides on top of `langfuse.*`
      defaults (image, resources, securityContext, nodeSelector,
      tolerations, affinity, etc.).
- [ ] Create `charts/langfuse/templates/secret.yaml`. Renders the
      postgres-baked Secret only (uses `lookup` to preserve across
      upgrades, `helm.sh/resource-policy: keep`, skipped when
      `postgres.mode != "baked"` or `postgres.baked.existingSecret`
      is set).
- [ ] Create `charts/langfuse/tests/helpers_test.yaml` with
      table-driven tests for every helper:
  - postgres mode dispatch (baked / cnpg / external)
  - valkey mode dispatch
  - fail-closed paths (each helper that calls `fail`)
  - commonEnv produces correct env entries per mode
  - podDefaults merges correctly when web/worker overrides set
- [ ] Create `charts/langfuse/tests/secret_test.yaml` covering:
  - postgres baked mode renders the Secret with `resource-policy: keep`
  - cnpg mode skips the Secret
  - external mode skips the Secret
  - baked mode skips the Secret when `postgres.baked.existingSecret` set
- [ ] Run `make helm-test`, confirm all suites pass.
- [ ] Commit `chart(langfuse): add helpers and secret strategy`.

#### Success Criteria

- All helper unit tests pass.
- `helm template charts/langfuse --set postgres.mode=external` fails
  with the actionable `postgres.external.existingSecret is required`
  message.
- `helm template charts/langfuse --set valkey.usePassword=true` (with
  no existingSecret) fails with the actionable Valkey error.
- `helm template charts/langfuse` (defaults) fails if
  `langfuse.auth.existingSecret`, `clickhouse.existingSecret`,
  `s3.existingSecret`, `s3.bucket`, etc. are unset — verifying
  fail-closed across the board.
- Postgres baked Secret renders with `helm.sh/resource-policy: keep`.

---

### Phase 3: Backing services (Postgres + Valkey)

Render the chart-deployed infrastructure for the two services we
support. This phase is independent of the application and can be
verified with `helm template` alone.

#### Tasks

- [ ] Create `templates/postgres-baked.yaml`. Guards: `postgres.mode == "baked"`. Renders:
  - StatefulSet (`<fullname>-postgres`) with `postgres:16` image,
    `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` env from the
    chart-managed Secret, `volumeClaimTemplates` when persistence
    enabled, default resources, security context (uid=999/gid=999).
  - Service (`<fullname>-postgres`, ClusterIP, port 5432).
- [ ] Create `templates/postgres-cnpg.yaml`. Guards:
      `postgres.mode == "cnpg"` and `postgres.cnpg.clusterName` set.
      Renders:
  - `postgresql.cnpg.io/v1` `Cluster` CR with `instances: 1`,
    `bootstrap.initdb.database` from values, sane resources defaults,
    and storage size derived from `postgres.cnpg.storage.size`.
  - Note: chart does NOT install or depend on the CNPG operator.
    If CRDs are missing, apply fails — same pattern as
    repo-guardian.
- [ ] Create `templates/valkey-baked.yaml`. Guards:
      `valkey.mode == "baked"`. Renders:
  - StatefulSet (`<fullname>-valkey`) with `valkey/valkey:9.0.3`
    image, `--requirepass $(VALKEY_PASSWORD)` arg when
    `valkey.usePassword: true`, persistence-enabled gates
    `volumeClaimTemplates`, default resources.
  - Service (`<fullname>-valkey`, ClusterIP, port 6379).
- [ ] Add `tests/postgres_baked_test.yaml`:
  - Renders StatefulSet + Service when `mode=baked`.
  - Skips both when `mode=cnpg` or `mode=external`.
  - PVC sized correctly per `postgres.baked.persistence.size`.
  - Wires the chart-managed Secret correctly.
- [ ] Add `tests/postgres_cnpg_test.yaml`:
  - Renders `Cluster` CR when `mode=cnpg` and `clusterName` set.
  - Skips when `mode=baked` or `mode=external`.
  - `Cluster.spec` references the right database / instances.
- [ ] Add `tests/valkey_test.yaml`:
  - Renders StatefulSet + Service when `mode=baked`.
  - Skips both when `mode=external`.
  - `--requirepass` arg present when `usePassword=true`.
  - `--requirepass` absent when `usePassword=false`.
  - Persistence-enabled vs disabled gates the `volumeClaimTemplates`.
- [ ] Run `make helm-test`, confirm.
- [ ] Render each mode combination with `helm template
      charts/langfuse --set ...` and eyeball the output.
- [ ] Commit `chart(langfuse): add postgres and valkey backend modes`.

#### Success Criteria

- All three Postgres modes render expected resources (or none).
- Valkey mode renders correctly under both modes and both
  persistence settings.
- All unit tests in this phase pass.
- `helm template` with `--set postgres.mode=cnpg --set
  postgres.cnpg.clusterName=test` produces a valid `Cluster` CR
  manifest.

---

### Phase 4: Web and Worker Deployments

Render the application Deployments and the Service that fronts the
web pod. This is where `commonEnv` becomes load-bearing.

#### Tasks

- [ ] Create `templates/web/deployment.yaml`. Guards: always renders.
  - Image: `langfuse/langfuse` + `langfuse.image.tag` (or
    appVersion fallback).
  - Replicas: `langfuse.web.replicas` defaulting to
    `langfuse.replicas`.
  - Container port 3000.
  - Env: `langfuse.commonEnv` + `langfuse.additionalEnv` +
    `langfuse.web.additionalEnv`.
  - EnvFrom: union of `langfuse.additionalEnvFrom` +
    `langfuse.web.additionalEnvFrom`.
  - Liveness: `GET /api/public/health` on port 3000.
  - Readiness: `GET /api/public/ready` on port 3000.
  - Resources, securityContext, podSecurityContext, nodeSelector,
    tolerations, affinity, dnsConfig, topologySpreadConstraints —
    all merged via `langfuse.podDefaults`.
  - extraContainers, extraVolumes, extraVolumeMounts,
    extraInitContainers, extraLifecycle hooks supported.
- [ ] Create `templates/web/service.yaml`. ClusterIP on
      `langfuse.web.service.port` (default 3000) → 3000. Always
      renders.
- [ ] Create `templates/worker/deployment.yaml`. Guards: always
      renders. Same shape as web but:
  - Image: `langfuse/langfuse-worker`.
  - Replicas: `langfuse.worker.replicas` defaulting to
    `langfuse.replicas`.
  - Container port 3030.
  - Liveness only: `GET /api/health` on port 3030. (No readiness;
    workers don't gate on traffic.)
  - No Service.
- [ ] Add `tests/web_deployment_test.yaml`:
  - Default values render the Deployment with expected env, image,
    replicas, probes.
  - `langfuse.web.replicas: 3` overrides `langfuse.replicas: 1`.
  - `langfuse.web.image.tag: "3.180.0"` overrides chart-default.
  - `langfuse.additionalEnv` merges into env.
  - `langfuse.web.additionalEnvFrom` merges into envFrom.
  - Postgres-baked mode wires `DATABASE_PASSWORD` from the
    chart-managed Secret.
  - Postgres-cnpg mode wires `DATABASE_PASSWORD` from the
    `<cluster>-app` Secret.
  - Postgres-external mode wires from the user-supplied Secret.
- [ ] Add `tests/worker_deployment_test.yaml` covering the same
      matrix as web but for the worker image and probes.
- [ ] Add `tests/web_service_test.yaml`:
  - Renders ClusterIP on the configured port.
  - Targets port 3000.
  - Selector matches the web Deployment.
- [ ] Run `make helm-test`, confirm.
- [ ] Render with default values + each backend-mode combination
      and eyeball.
- [ ] Commit `chart(langfuse): add web and worker deployments`.

#### Success Criteria

- Web and worker Deployments render under default values.
- Inheritance from `langfuse.*` works: setting only
  `langfuse.replicas: 3` propagates to both web and worker.
- Per-deployment overrides win: `langfuse.web.replicas: 5` overrides
  the inherited value.
- All env vars wire correctly across the three Postgres modes
  (baked / cnpg / external) and two Valkey modes (baked / external).
- All unit tests in this phase pass.

---

### Phase 5: Ingress and Gateway API

Render the optional north-south path. Both classic Ingress and
Gateway API HTTPRoute live under `langfuse.*` per DESIGN-0003.

#### Tasks

- [ ] Create `templates/ingress.yaml`. Guards:
      `langfuse.ingress.enabled`. Renders standard `Ingress` with
      `className`, `annotations`, hosts/paths, TLS — same shape as
      fleetdm.
- [ ] Create `templates/httproute.yaml`. Guards:
      `langfuse.httpRoute.enabled` AND non-empty
      `langfuse.httpRoute.parentRefs`. Vanilla
      `gateway.networking.k8s.io/v1` `HTTPRoute` referencing the
      web Service on port 3000.
- [ ] Create `templates/certificate.yaml`. Guards:
      `langfuse.httpRoute.certManager.enabled`. cert-manager
      `Certificate` referencing the configured `clusterIssuer`.
- [ ] Add `tests/ingress_test.yaml`:
  - Renders only when enabled.
  - className, hosts, paths, TLS pass through.
- [ ] Add `tests/httproute_test.yaml`:
  - Renders only when enabled AND parentRefs non-empty.
  - Skips when enabled but parentRefs empty (safe-default pattern).
  - Hostname, parentRefs, port-3000 backend ref correct.
- [ ] Add `tests/certificate_test.yaml`:
  - Renders only when enabled.
  - clusterIssuer, dnsNames, secretName correct.
- [ ] Render with each combination and eyeball.
- [ ] Commit `chart(langfuse): add ingress and gateway api templates`.

#### Success Criteria

- Default values render no Ingress (since hosts is empty) but
  `langfuse.ingress.enabled: true` with a configured host produces
  a valid Ingress.
- `langfuse.httpRoute.enabled: true` with empty parentRefs renders
  nothing (safe default); with parentRefs renders a vanilla
  `HTTPRoute`.
- All tests in this phase pass.

---

### Phase 6: helm-test, examples, and docs

Make the chart deployable AND understandable.

#### Tasks

- [ ] Create `templates/tests/test-postgres.yaml` —
      `helm.sh/hook: test` Pod that runs `pg_isready -h $HOST` (or
      `psql -c 'SELECT 1'`) against the configured Postgres host.
      Skips in `postgres.mode=external` if the user opts out
      (`tests.postgres.enabled: true` default).
- [ ] Create `templates/tests/test-valkey.yaml` — `helm.sh/hook:
      test` Pod that runs `redis-cli -h $HOST PING`.
- [ ] Create `templates/tests/test-langfuse.yaml` — `helm.sh/hook:
      test` Pod that runs `curl -fsS
      http://<fullname>-web:3000/api/public/health`.
- [ ] All test pods pass Trivy misconfig scans (full pod + container
      security contexts, matching the fleetdm pattern).
- [ ] Create `examples/clickhouse-cluster.yaml` — a
      ClickHouse Operator `Cluster` CR example with comments
      explaining the URL/port/credentials it produces and how to
      wire `clickhouse.url` / `clickhouse.migrationUrl` /
      `clickhouse.existingSecret` from it.
- [ ] Write `README.md.gotmpl`. Sections:
  - Prerequisites table (K8s, Helm, ClickHouse, S3, optional CNPG /
    Gateway API CRDs)
  - Installation snippets (default / external infra / CNPG)
  - Backing services explanation (linking DESIGN-0003)
  - Secret management (linking INV-0001)
  - Post-install validation (`helm test`)
  - chart-template-rendered values table (`{{ template
    "chart.valuesSection" . }}`)
- [ ] Run `make helm-docs`, commit the regenerated `README.md`.
- [ ] Run `make helm-docs-check`, confirm clean.
- [ ] Commit `chart(langfuse): add helm-test hooks, example, and readme`.

#### Success Criteria

- `helm test <release>` runs all three connectivity probes
  (Postgres, Valkey, Langfuse health).
- README documents every user-facing values knob.
- ClickHouse Operator example is documented and renders cleanly
  with `kubectl apply --dry-run=client -f
  examples/clickhouse-cluster.yaml` (CRDs not required for
  client-side validation).
- `make helm-docs-check` clean.

---

### Phase 7: CI integration and PR

Get the chart through `ct lint` in both representative configs,
then ship.

#### Tasks

- [ ] Create `ci/default-values.yaml`:
  - `postgres.mode=baked`, `valkey.mode=baked`.
  - `langfuse.auth.existingSecret: langfuse-auth-stub`.
  - `clickhouse.url: http://stub-clickhouse:8123`,
    `migrationUrl: clickhouse://stub-clickhouse:9000`,
    `existingSecret: langfuse-clickhouse-stub`.
  - `s3.bucket: langfuse-events`, `s3.endpoint:
    https://s3.example.com`, `existingSecret: langfuse-s3-stub`.
  - Resources reduced for CI.
- [ ] Create `ci/external-values.yaml`:
  - `postgres.mode=external` with stubbed host + existingSecret.
  - `valkey.mode=external` with stubbed host + existingSecret.
  - Same auth/clickhouse/s3 stubs as default.
- [ ] Create `ci/cnpg-values.yaml`:
  - `postgres.mode=cnpg` with `clusterName: langfuse-pg`.
  - `valkey.mode=baked`.
  - Same auth/clickhouse/s3 stubs.
- [ ] Run `make helm-ct-lint` locally, confirm all three configs
      pass.
- [ ] Run `make helm-test`, confirm all unit suites pass.
- [ ] Run `make helm-docs-check`, confirm clean.
- [ ] Push branch.
- [ ] Open the PR. Reference DESIGN-0003 in the body.
- [ ] Confirm all CI jobs go green:
  - Helm Lint
  - Helm Unit Tests
  - Helm Docs Check
  - Security Scan (Trivy)
  - Chart Testing (`ct lint`)
  - Chart Version Check
  - Validate Renovate Config
- [ ] Merge.

#### Success Criteria

- `make helm-test`, `make helm-ct-lint`, `make helm-docs-check`
  all green locally.
- All seven CI jobs green on the PR.
- Chart Version Check passes (Chart.yaml version is `0.1.0` and
  this is the chart's first ship).
- PR merged to main.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `charts/langfuse/Chart.yaml` | Create | Chart metadata, version 0.1.0, appVersion 3.172.1 |
| `charts/langfuse/values.yaml` | Create | Full values shape per DESIGN-0003 |
| `charts/langfuse/values.schema.json` | Create | Mode enum validation, log-level/format enums |
| `charts/langfuse/.helmignore` | Create | Standard ignores |
| `charts/langfuse/README.md.gotmpl` | Create | helm-docs template |
| `charts/langfuse/README.md` | Create | Generated by helm-docs |
| `charts/langfuse/templates/_helpers.tpl` | Create | Name helpers, mode dispatch, fail-closed paths, commonEnv, podDefaults |
| `charts/langfuse/templates/serviceaccount.yaml` | Create | Optional ServiceAccount |
| `charts/langfuse/templates/secret.yaml` | Create | Postgres-baked-mode Secret only |
| `charts/langfuse/templates/postgres-baked.yaml` | Create | StatefulSet + Service for `postgres.mode=baked` |
| `charts/langfuse/templates/postgres-cnpg.yaml` | Create | CNPG `Cluster` CR for `postgres.mode=cnpg` |
| `charts/langfuse/templates/valkey-baked.yaml` | Create | StatefulSet + Service for `valkey.mode=baked` |
| `charts/langfuse/templates/web/deployment.yaml` | Create | langfuse-web Deployment |
| `charts/langfuse/templates/web/service.yaml` | Create | langfuse-web Service |
| `charts/langfuse/templates/worker/deployment.yaml` | Create | langfuse-worker Deployment |
| `charts/langfuse/templates/ingress.yaml` | Create | Classic Ingress (default-on, but skipped without hosts) |
| `charts/langfuse/templates/httproute.yaml` | Create | Gateway API HTTPRoute (default-off) |
| `charts/langfuse/templates/certificate.yaml` | Create | cert-manager Certificate (httpRoute path) |
| `charts/langfuse/templates/NOTES.txt` | Create | Post-install notes |
| `charts/langfuse/templates/tests/test-postgres.yaml` | Create | helm-test connectivity hook |
| `charts/langfuse/templates/tests/test-valkey.yaml` | Create | helm-test connectivity hook |
| `charts/langfuse/templates/tests/test-langfuse.yaml` | Create | helm-test /api/public/health probe |
| `charts/langfuse/tests/helpers_test.yaml` | Create | Helper unit tests |
| `charts/langfuse/tests/secret_test.yaml` | Create | Postgres-baked Secret tests |
| `charts/langfuse/tests/postgres_baked_test.yaml` | Create | Postgres baked-mode unit tests |
| `charts/langfuse/tests/postgres_cnpg_test.yaml` | Create | Postgres cnpg-mode unit tests |
| `charts/langfuse/tests/valkey_test.yaml` | Create | Valkey unit tests |
| `charts/langfuse/tests/web_deployment_test.yaml` | Create | Web deployment unit tests |
| `charts/langfuse/tests/web_service_test.yaml` | Create | Web service unit tests |
| `charts/langfuse/tests/worker_deployment_test.yaml` | Create | Worker deployment unit tests |
| `charts/langfuse/tests/ingress_test.yaml` | Create | Ingress unit tests |
| `charts/langfuse/tests/httproute_test.yaml` | Create | HTTPRoute unit tests |
| `charts/langfuse/tests/certificate_test.yaml` | Create | Certificate unit tests |
| `charts/langfuse/ci/default-values.yaml` | Create | baked + baked CI config |
| `charts/langfuse/ci/external-values.yaml` | Create | external + external CI config |
| `charts/langfuse/ci/cnpg-values.yaml` | Create | cnpg + baked CI config |
| `charts/langfuse/examples/clickhouse-cluster.yaml` | Create | ClickHouse Operator Cluster CR example |

## Testing Plan

- **Unit tests (`helm-unittest`)** — at least 12 suites covering
  helpers, secret, postgres-baked, postgres-cnpg, valkey,
  web/deployment, web/service, worker/deployment, ingress, httproute,
  certificate, plus a minimal serviceaccount test. Target: ~80–100
  tests.
- **`ct lint`** — runs against all three CI values files
  (`default-values.yaml`, `external-values.yaml`,
  `cnpg-values.yaml`). The `cnpg-values.yaml` config will not
  install in Kind (CNPG operator absent in CI), but `ct lint` only
  validates the rendered manifests — that's enough for v0.1.
- **`ct install`** — deferred. ClickHouse and S3 are hard
  dependencies of the application; a green install would need stub
  Deployments for both, which is out of scope for v0.1. The
  `ct install` step will be skipped via the `excludeCharts:
  [langfuse]` lever in `ct.yaml` (or skipped in the CI workflow
  if simpler).
- **helm-test** — connectivity probes for Postgres, Valkey, and
  Langfuse `/api/public/health`. Manual / homelab smoke test only;
  not part of automated CI.
- **Render-path verification** — for each combination of
  `postgres.mode` × `valkey.mode` × ingress/httpRoute, run `helm
  template` and eyeball the env vars and resource shape.

## Dependencies

- **Internal**: none.
- **External (chart consumers)**:
  - **Required** at install time:
    - A ClickHouse cluster reachable from the namespace (via
      ClickHouse Operator or external).
    - An S3-compatible bucket and credentials.
    - A Secret containing `nextauth-secret`, `encryption-key`, `salt`
      (32-byte values; openssl rand -base64 32 works for each).
  - **Optional**:
    - CNPG operator if `postgres.mode=cnpg`.
    - Gateway API CRDs if `langfuse.httpRoute.enabled=true`.
    - cert-manager if `langfuse.httpRoute.certManager.enabled=true`.
- **CI**:
  - `Chart Version Check` job — first-ship of `langfuse` won't have
    a previous version to diff; verify the job handles new-chart
    introduction (it should — fleetdm went through the same
    introduction in IMPL-0002).

## Open Questions

None remaining. All resolved in the [Decisions](#decisions) table.

## References

- [DESIGN-0003 — Langfuse Helm chart][design-0003]
- [INV-0001 — fleetdm secret regeneration under helm template][inv-0001]
- [Issue #17 — adopt idiomatic Helm secret pattern][issue-17]
- [Upstream Langfuse k8s chart](https://github.com/langfuse/langfuse-k8s/tree/main/charts/langfuse)
- [Langfuse v3 self-hosting infra docs](https://langfuse.com/self-hosting/infrastructure)
- [ClickHouse Operator](https://github.com/ClickHouse/clickhouse-operator)
- [CloudNativePG](https://cloudnative-pg.io/)
- [repo-guardian backend-modes pattern](https://github.com/donaldgifford/repo-guardian/blob/docs/design-persistent-reconcile-state/docs/design/0012-persistent-reconcile-state-and-multi-replica-coordination.md#backend-modes-and-chart-deployment-shapes)

[design-0003]: ../design/0003-langfuse-helm-chart.md
[inv-0001]: ../investigation/0001-fleetdm-secret-regeneration-under-helm-template.md
[issue-17]: https://github.com/donaldgifford/helm-charts/issues/17
