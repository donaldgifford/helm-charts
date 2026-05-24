---
id: IMPL-0004
title: "Build chartdb helm chart v0.1.0"
status: InProgress
author: Donald Gifford
created: 2026-05-24
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0004: Build chartdb helm chart v0.1.0

**Status:** InProgress
**Author:** Donald Gifford
**Date:** 2026-05-24

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
  - [Phase 2: Deployment, Service, and security context](#phase-2-deployment-service-and-security-context)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Ingress and Gateway API](#phase-3-ingress-and-gateway-api)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: helm-test, docs, and NOTES](#phase-4-helm-test-docs-and-notes)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: CI integration and PR](#phase-5-ci-integration-and-pr)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Exact list of `emptyDir` paths needed for `readOnlyRootFilesystem: true`? | Start with `/etc/nginx/conf.d/`, `/var/cache/nginx/`, `/var/run/`, `/tmp/`. Audit live in Phase 2 by `helm install` into Kind and reading pod logs for permission errors. Add paths as needed and document the final list in `values.yaml` comments. Escalate if `/usr/share/nginx/html/` (static-asset path) is required. |
| 2 | helm-test target path? | `curl /` (SPA index). Matches the readiness probe; `/config.js` may 404 transiently if the entrypoint hasn't rendered it yet. |
| 3 | Extensibility hooks (`additionalEnv`, `extraContainers`, `extraVolumes`, etc.) in v0.1? | Ship them. Zero template cost, matches the langfuse chart, supports power users who want sidecars. |
| 4 | `emptyDir` size limits? | Leave defaults in v0.1. nginx caches are tiny. |
| 5 | nginx tuning knobs (worker_processes, worker_connections)? | Skip in v0.1. Users who need tuning override via `extraContainers` + custom args. |
| 6 | Deployment naming? | `<release>-chartdb` via `chartdb.fullname` helper. Consistent with other charts in this repo. |
| 7 | OpenAI literal-value env vars: render only when non-empty, or always render? | Render only when non-empty. Upstream's `default.conf.template` treats unset and empty the same, so we save noise. |
| 8 | `HIDE_CHARTDB_CLOUD` / `DISABLE_ANALYTICS` env shape? | String `"true"` / `"false"`. nginx env templating is string-only. |
| 9 | Should `ct.yaml` change to accommodate the new chart? | No. chartdb is small and fast; use defaults. |
| 10 | NOTES.txt — include `kubectl port-forward` for default install? | Yes — `kubectl port-forward svc/<fullname> 8080:80` plus `open http://localhost:8080`. |
| 11 | Expose Service-level `nodePort` value for `NodePort` Service type? | No. Keep values surface small; users override via post-render patch if needed. |

## Objective

Build the first release (`0.1.0`) of a slim `chartdb` Helm chart per
[DESIGN-0003][design-0003]. The chart deploys ChartDB (a single
nginx-served React SPA) with zero backing services, secure defaults,
and the same north-south access conventions used by the other charts
in this repo.

**Implements:** [DESIGN-0003 — ChartDB Helm chart][design-0003]

## Scope

### In Scope

- New chart at `charts/chartdb/` with `Chart.yaml`, `values.yaml`,
  `values.schema.json`, `templates/`, `tests/`, `ci/`,
  `README.md.gotmpl`, and `.helmignore`.
- Single `Deployment` + `ClusterIP Service` rendering the upstream
  `ghcr.io/chartdb/chartdb:1.20.1` image.
- Pod security defaults: `runAsNonRoot: true`, `runAsUser: 101`,
  `readOnlyRootFilesystem: true` with `emptyDir` mounts over the
  writable paths the upstream entrypoint and nginx need
  (`/etc/nginx/conf.d/`, `/var/cache/nginx/`, `/var/run/`, `/tmp/`),
  `capabilities: drop: [ALL]` + `add: [NET_BIND_SERVICE]`.
- `chartdb.*` namespace for all app-shaped values (no top-level
  knobs except `nameOverride` / `fullnameOverride`).
- Runtime env wiring for ChartDB's optional vars:
  `OPENAI_API_KEY` (existingSecret only, helper fails closed when
  enabled), plus literal-value vars: `OPENAI_API_ENDPOINT`,
  `LLM_MODEL_NAME`, `HIDE_CHARTDB_CLOUD`, `DISABLE_ANALYTICS`.
- Optional `ServiceAccount` (`create: true` default,
  `automountServiceAccountToken: false`).
- Classic `Ingress` (default-on) and vanilla Gateway API `HTTPRoute`
  (default-off, guarded on non-empty `parentRefs`) under
  `chartdb.ingress.*` and `chartdb.httpRoute.*`.
- Optional cert-manager `Certificate` for the HTTPRoute TLS path.
- Extensibility hooks: `additionalEnv`, `additionalEnvFrom`,
  `extraContainers`, `extraVolumes`, `extraVolumeMounts`,
  `extraInitContainers`, `extraLifecycle`.
- helm-unittest suites covering each rendered template.
- CI values: `default-values.yaml`, `openai-values.yaml`.
- helm-test connectivity hook (curl against the Service).
- `make helm-ct-install` in Kind — feasible here since there are no
  backing services.
- Renovate annotation on `appVersion`
  (`# renovate: image=ghcr.io/chartdb/chartdb`).

### Out of Scope

- HPA, KEDA, VPA, PDB. (Deferred — chart is stateless so HPA is
  trivially addable later.)
- Init container approach to drop `NET_BIND_SERVICE`. (Documented as
  v0.2 Future Consideration in DESIGN-0003.)
- NetworkPolicy template. (Deferred.)
- Build-time `VITE_*` env vars. (Users who want a custom build fork
  the image, not the chart.)
- Custom nginx config rendering. (We use upstream's
  `default.conf.template` untouched.)
- ConfigMap for nginx tuning. (Deferred.)

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met. Commit
after each numbered task with conventional commits scoped to
`chart(chartdb)`.

---

### Phase 1: Chart scaffold

Create the directory layout, the metadata files, and a minimal set
of templates that lint cleanly. Establishes the floor for every
later phase.

#### Tasks

- [x] Create `charts/chartdb/Chart.yaml`:
  - `apiVersion: v2`
  - `name: chartdb`
  - `description: A Helm chart for ChartDB — open-source database diagram editor`
  - `type: application`
  - `version: 0.1.0`
  - `appVersion: "1.20.1"` with `# renovate: image=ghcr.io/chartdb/chartdb` on the line above
  - `home: https://chartdb.io`
  - `sources: [https://github.com/chartdb/chartdb, https://github.com/donaldgifford/helm-charts]`
  - `keywords: [chartdb, database, schema, diagram, erd, visualization]`
  - `maintainers: [Donald Gifford]`
  - `dependencies: []`
- [x] Create `charts/chartdb/.helmignore` (mirror fleetdm).
- [x] Create `charts/chartdb/values.yaml` matching DESIGN-0003 §API
      shape, with `--` comments for every user-facing knob (helm-docs
      format). Document `existingSecret` requirement explicitly for
      `chartdb.openai`.
- [x] Create `charts/chartdb/values.schema.json` with at minimum:
  - `chartdb.service.type`: `enum: ["ClusterIP", "NodePort", "LoadBalancer"]`
  - `chartdb.image.pullPolicy`: `enum: ["Always", "IfNotPresent", "Never"]`
  - `chartdb.replicaCount`: `type: integer, minimum: 0`
- [x] Create `charts/chartdb/templates/_helpers.tpl` with the
      standard Helm name helpers: `chartdb.name`, `chartdb.fullname`,
      `chartdb.chart`, `chartdb.labels`, `chartdb.selectorLabels`,
      `chartdb.serviceAccountName`. Plus a custom helper
      `chartdb.openaiSecretName` that fails closed when
      `chartdb.openai.enabled: true` AND `existingSecret` empty.
- [x] Create `charts/chartdb/templates/serviceaccount.yaml` (renders
      under `chartdb.serviceAccount.create: true`,
      `automountServiceAccountToken: false` by default).
- [x] Create `charts/chartdb/templates/NOTES.txt` placeholder
      (full content in Phase 4).
- [x] Create `charts/chartdb/README.md.gotmpl` placeholder
      (full content in Phase 4).
- [x] Run `make helm-docs` to generate `charts/chartdb/README.md`.
- [x] Run `make helm-lint` and confirm clean.
- [x] Run `make helm-template` and confirm only the ServiceAccount
      renders for default values.
- [x] Commit `chart(chartdb): scaffold chart skeleton`.

#### Success Criteria

- `helm lint charts/chartdb` passes with zero errors.
- `helm template charts/chartdb` renders only the ServiceAccount.
- `make helm-docs-check` reports no drift.
- `Chart.yaml` `version: 0.1.0`, `appVersion: 1.20.1`.

---

### Phase 2: Deployment, Service, and security context

Render the application Deployment + Service. Wire all the runtime
env vars correctly, including the OpenAI existingSecret fail-closed
path. Validate `readOnlyRootFilesystem: true` + `NET_BIND_SERVICE`
actually works against the upstream image (this is the highest-risk
verification in the chart — if it doesn't work, we adjust the
writable paths here).

#### Tasks

- [x] Create `charts/chartdb/templates/deployment.yaml`. Renders the
      single Deployment with:
  - Image: `ghcr.io/chartdb/chartdb` + `chartdb.image.tag` (or
    appVersion fallback).
  - Replicas: `chartdb.replicaCount`.
  - Container port: 80 (named `http`).
  - Pod-level securityContext: `runAsNonRoot: true`, `runAsUser:
    101`, `runAsGroup: 101`, `fsGroup: 101`, `seccompProfile:
    RuntimeDefault`.
  - Container-level securityContext: `readOnlyRootFilesystem: true`,
    `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`
    + `add: [NET_BIND_SERVICE]`.
  - `volumes`: one `emptyDir` per writable path (initial set:
    `/etc/nginx/conf.d/`, `/var/cache/nginx/`, `/var/run/`,
    `/tmp/`). Audit during this phase — if the upstream entrypoint
    writes to other paths, add them. `volumeMounts` reference each.
  - Liveness + readiness probes: `httpGet /` on port `http`.
  - Resources: defaults from DESIGN-0003 (`requests: 10m / 32Mi`,
    `limits: 128Mi`).
  - Env: `commonEnv` helper assembles `OPENAI_API_KEY` (via
    `secretKeyRef` referencing the helper), `OPENAI_API_ENDPOINT`
    / `LLM_MODEL_NAME` (literal), and `HIDE_CHARTDB_CLOUD` /
    `DISABLE_ANALYTICS` (`"true"` / `"false"` string per
    nginx-template's expectations). Render env only when set —
    don't emit empty-string envs.
  - `additionalEnv` / `additionalEnvFrom` / `extraContainers` /
    `extraVolumes` / `extraVolumeMounts` / `extraInitContainers` /
    `extraLifecycle` all merge in.
  - nodeSelector, tolerations, affinity,
    topologySpreadConstraints, podAnnotations, podLabels.
- [x] Create `charts/chartdb/templates/service.yaml`. ClusterIP on
      `chartdb.service.port` (default 80) → `targetPort: 80`. Always
      renders.
- [x] Add `charts/chartdb/tests/deployment_test.yaml`:
  - Default values render the Deployment with expected image,
    replicas, port, probes, securityContext, capabilities.
  - emptyDir volumes mounted at the four required paths.
  - `chartdb.image.tag` override wins over appVersion default.
  - `chartdb.replicaCount: 3` propagates.
  - `chartdb.openai.enabled: true` with `existingSecret: foo` wires
    `OPENAI_API_KEY` via `secretKeyRef.name=foo,
    key=chartdb.openai.apiKeyKey`.
  - `chartdb.openai.enabled: true` with no `existingSecret` fails
    rendering with the actionable error.
  - `chartdb.openai.enabled: false` omits `OPENAI_API_KEY` entirely
    (no empty env entry).
  - Literal env vars (`OPENAI_API_ENDPOINT`, etc.) only render when
    set.
  - `additionalEnv` merges into env list.
  - `additionalEnvFrom` merges into envFrom list.
  - nodeSelector/tolerations/affinity pass through.
- [x] Add `charts/chartdb/tests/service_test.yaml`:
  - Renders ClusterIP on port 80 by default.
  - Selector matches Deployment's labels.
  - Port name `http`, targetPort 80.
- [x] Add `charts/chartdb/tests/helpers_test.yaml`:
  - `chartdb.openaiSecretName` returns existingSecret when set.
  - `chartdb.openaiSecretName` fails closed when enabled with no
    secret.
  - Standard name/fullname helpers behave per Helm convention.
- [x] Validate the read-only-rootfs + NET_BIND_SERVICE combo
      against the actual upstream image (manual `helm install` into
      Kind). **Discovery:** upstream's `default.conf.template` lives
      at `/etc/nginx/conf.d/default.conf.template` in the image.
      Mounting an `emptyDir` over that directory masks the template
      and the entrypoint's envsubst fails. **Fix:** added a
      `seed-nginx-template` init container that copies the template
      from the image into the shared `emptyDir` before the main
      container starts. Verified end-to-end in Kind: pod
      `Running 1/1`, probes returning 200, `curl /` returns the
      SPA `index.html` (2124 bytes), no permission errors. The four
      writable paths (`/etc/nginx/conf.d/`, `/var/cache/nginx/`,
      `/var/run/`, `/tmp/`) are sufficient.
- [x] Run `make helm-test`, confirm. (123/123 tests pass.)
- [x] Run `make helm-template charts/chartdb`, eyeball. (ServiceAccount
      + Service + Deployment with seed-nginx-template init container.)
- [x] Commit `chart(chartdb): add deployment and service`.

#### Success Criteria

- Deployment + Service render under default values.
- All env-wiring permutations covered by unit tests pass.
- `chartdb.openai.enabled: true` without `existingSecret` fails
  with actionable error.
- Manual `helm install` in Kind: pod reaches `Running`,
  `Ready 1/1`, no permission errors in logs. `curl
  http://<service>/` returns the ChartDB SPA's `index.html`.
- All unit tests in this phase pass.

---

### Phase 3: Ingress and Gateway API

Add the optional north-south path. Both shapes live under
`chartdb.*` per DESIGN-0003.

#### Tasks

- [ ] Create `charts/chartdb/templates/ingress.yaml`. Guards:
      `chartdb.ingress.enabled` AND non-empty
      `chartdb.ingress.hosts`. Renders classic `Ingress` with
      `className`, `annotations`, hosts/paths, TLS — same shape as
      fleetdm.
- [ ] Create `charts/chartdb/templates/httproute.yaml`. Guards:
      `chartdb.httpRoute.enabled` AND non-empty
      `chartdb.httpRoute.parentRefs`. Vanilla
      `gateway.networking.k8s.io/v1` `HTTPRoute` referencing the
      Service on port 80.
- [ ] Create `charts/chartdb/templates/certificate.yaml`. Guards:
      `chartdb.httpRoute.certManager.enabled`. cert-manager
      `Certificate` referencing the configured `clusterIssuer`,
      `dnsNames: [hostname]`, `secretName` for the TLS cert.
- [ ] Add `charts/chartdb/tests/ingress_test.yaml`:
  - Renders only when enabled AND hosts non-empty.
  - className, annotations, hosts, paths, TLS pass through.
- [ ] Add `charts/chartdb/tests/httproute_test.yaml`:
  - Renders only when enabled AND parentRefs non-empty (safe-default
    pattern matching fleetdm/langfuse).
  - Hostname, parentRefs, port-80 backend ref correct.
- [ ] Add `charts/chartdb/tests/certificate_test.yaml`:
  - Renders only when cert-manager block enabled.
  - clusterIssuer, dnsNames, secretName correct.
- [ ] Run `make helm-test`, confirm.
- [ ] Render each combination with `helm template` and eyeball.
- [ ] Commit `chart(chartdb): add ingress and gateway api templates`.

#### Success Criteria

- Default values render no Ingress (since `hosts: []` empty) but
  `chartdb.ingress.enabled: true` with a configured host produces
  a valid Ingress.
- `chartdb.httpRoute.enabled: true` with empty parentRefs renders
  nothing; with parentRefs renders vanilla `HTTPRoute`.
- All tests in this phase pass.

---

### Phase 4: helm-test, docs, and NOTES

Make the chart usable and understandable.

#### Tasks

- [ ] Create `charts/chartdb/templates/tests/test-connection.yaml`
      — `helm.sh/hook: test` Pod that runs `curl -fsS
      http://<fullname>:80/` (the SPA index). Hook policies
      `before-hook-creation,hook-succeeded`. Full pod + container
      security context (matches the fleetdm test pod's Trivy-clean
      shape).
- [ ] Write `charts/chartdb/templates/NOTES.txt`:
  - One-line congrats.
  - kubectl port-forward example for default install (no Ingress
    configured): `kubectl port-forward svc/<fullname> 8080:80`.
  - URL hint when Ingress or HTTPRoute is configured.
  - Reminder: `chartdb.openai.existingSecret` required if
    `chartdb.openai.enabled: true`.
  - `helm test <release>` instruction.
- [ ] Write `charts/chartdb/README.md.gotmpl`. Sections:
  - Prerequisites table (K8s, Helm, optional Gateway API CRDs,
    optional cert-manager).
  - Installation snippets (default / Ingress / Gateway API /
    OpenAI-enabled).
  - Configuration section linking DESIGN-0003.
  - Secret management section (linking INV-0001).
  - Post-install validation (`helm test`).
  - chart-template-rendered values table.
- [ ] Run `make helm-docs`, commit the regenerated `README.md`.
- [ ] Run `make helm-docs-check`, confirm clean.
- [ ] Commit `chart(chartdb): add helm-test hook, notes, and readme`.

#### Success Criteria

- `helm test <release>` runs the curl probe and succeeds against a
  freshly installed release.
- README documents every user-facing values knob.
- NOTES.txt prints sensible post-install info under all
  default/ingress/httpRoute combinations.
- `make helm-docs-check` clean.

---

### Phase 5: CI integration and PR

Get the chart through `ct lint` (both representative configs) AND
`ct install` in Kind (feasible since chartdb has no external
dependencies), then ship.

#### Tasks

- [ ] Create `charts/chartdb/ci/default-values.yaml`:
  - Minimal overrides for CI: reduced resources, `ingress.enabled:
    false` (no controller in CI), `httpRoute.enabled: false`.
- [ ] Create `charts/chartdb/ci/openai-values.yaml`:
  - `chartdb.openai.enabled: true`, `existingSecret:
    chartdb-openai-stub`, the rest minimal.
- [ ] Verify `ct.yaml` includes `chartdb` (no `excludeCharts` lever
      needed — unlike langfuse, chartdb supports `ct install`).
- [ ] Run `make helm-test`, confirm all unit suites pass.
- [ ] Run `make helm-ct-lint` locally with both CI configs.
- [ ] Run `make helm-ct-install` locally in Kind, confirm install
      succeeds and helm test passes.
- [ ] Run `make helm-docs-check`, confirm clean.
- [ ] Push branch.
- [ ] Open the PR. Reference DESIGN-0003 in the body.
- [ ] Confirm all CI jobs go green:
  - Helm Lint
  - Helm Unit Tests
  - Helm Docs Check
  - Security Scan (Trivy)
  - Chart Testing (`ct lint` + `ct install` in Kind)
  - Chart Version Check
  - Validate Renovate Config
- [ ] Merge.

#### Success Criteria

- `make helm-test`, `make helm-ct-lint`, `make helm-ct-install`,
  `make helm-docs-check` all green locally.
- All seven CI jobs green on the PR.
- PR merged to main.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `charts/chartdb/Chart.yaml` | Create | Chart metadata, version 0.1.0, appVersion 1.20.1 |
| `charts/chartdb/values.yaml` | Create | Full values shape per DESIGN-0003 |
| `charts/chartdb/values.schema.json` | Create | Service type / pullPolicy enums, replicaCount validation |
| `charts/chartdb/.helmignore` | Create | Standard ignores |
| `charts/chartdb/README.md.gotmpl` | Create | helm-docs template |
| `charts/chartdb/README.md` | Create | Generated by helm-docs |
| `charts/chartdb/templates/_helpers.tpl` | Create | Name helpers + openaiSecretName fail-closed |
| `charts/chartdb/templates/serviceaccount.yaml` | Create | Optional ServiceAccount |
| `charts/chartdb/templates/deployment.yaml` | Create | Single chartdb Deployment with security context + emptyDirs |
| `charts/chartdb/templates/service.yaml` | Create | ClusterIP Service on port 80 |
| `charts/chartdb/templates/ingress.yaml` | Create | Classic Ingress (default-on, guarded on hosts) |
| `charts/chartdb/templates/httproute.yaml` | Create | Gateway API HTTPRoute (default-off, guarded on parentRefs) |
| `charts/chartdb/templates/certificate.yaml` | Create | cert-manager Certificate (httpRoute path) |
| `charts/chartdb/templates/NOTES.txt` | Create | Post-install notes |
| `charts/chartdb/templates/tests/test-connection.yaml` | Create | helm-test curl hook |
| `charts/chartdb/tests/deployment_test.yaml` | Create | Deployment unit tests |
| `charts/chartdb/tests/service_test.yaml` | Create | Service unit tests |
| `charts/chartdb/tests/helpers_test.yaml` | Create | Helper unit tests (openaiSecretName fail-closed) |
| `charts/chartdb/tests/ingress_test.yaml` | Create | Ingress unit tests |
| `charts/chartdb/tests/httproute_test.yaml` | Create | HTTPRoute unit tests |
| `charts/chartdb/tests/certificate_test.yaml` | Create | Certificate unit tests |
| `charts/chartdb/ci/default-values.yaml` | Create | Default CI config |
| `charts/chartdb/ci/openai-values.yaml` | Create | OpenAI-enabled CI config |

## Testing Plan

- **Unit tests (`helm-unittest`)** — 6 suites, target ~25–35 tests:
  deployment, service, helpers, ingress, httproute, certificate.
- **`ct lint`** — both CI values files
  (`default-values.yaml`, `openai-values.yaml`).
- **`ct install`** in Kind — feasible for this chart since there
  are no external dependencies. Default values install cleanly and
  helm-test passes.
- **helm-test** — single curl-against-Service connectivity hook.
- **Manual smoke test** in Phase 2 — confirms the
  `readOnlyRootFilesystem + NET_BIND_SERVICE` combo works against
  the actual upstream image. This is the highest-risk verification
  in the chart.

## Dependencies

- **Internal**: none.
- **External (chart consumers)**:
  - **Required** at install time: nothing — the chart works with
    `helm install chartdb donaldgifford/chartdb` and zero overrides.
  - **Optional**:
    - Gateway API CRDs if `chartdb.httpRoute.enabled: true`.
    - cert-manager if `chartdb.httpRoute.certManager.enabled: true`.
    - A Secret containing the OpenAI API key if
      `chartdb.openai.enabled: true`.
- **CI**:
  - `Chart Version Check` job — first-ship of `chartdb` won't have
    a previous version to diff; should be handled gracefully
    (fleetdm + langfuse went through the same first-ship
    introduction).
  - Trivy security scan — chart-rendered manifests should pass
    HIGH/CRITICAL filters.

## Open Questions

None remaining. All resolved in the [Decisions](#decisions) table.

## References

- [DESIGN-0003 — ChartDB Helm chart][design-0003]
- [INV-0001 — fleetdm secret regeneration under helm template][inv-0001]
- [ChartDB GitHub repository](https://github.com/chartdb/chartdb)
- [ChartDB upstream Dockerfile](https://github.com/chartdb/chartdb/blob/main/Dockerfile)
- [ChartDB upstream nginx config template](https://github.com/chartdb/chartdb/blob/main/default.conf.template)
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

[design-0003]: ../design/0003-chartdb-helm-chart.md
[inv-0001]: ../investigation/0001-fleetdm-secret-regeneration-under-helm-template.md
