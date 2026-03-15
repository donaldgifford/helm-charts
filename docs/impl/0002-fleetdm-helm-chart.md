---
id: IMPL-0002
title: "FleetDM Helm Chart"
status: Draft
author: Donald Gifford
created: 2026-03-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0002: FleetDM Helm Chart

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-03-15

## Objective

Implement the FleetDM Helm chart as described in DESIGN-0001. The chart replaces the
upstream FleetDM chart's broken Bitnami subcharts with a PXC-backed MySQL integration,
optional Valkey cache, Gateway API HTTPRoute (default) + classic Ingress (optional), and
the existingSecret pattern throughout.

**Implements:** [DESIGN-0001](../design/0001-fleetdm-helm-chart.md)

## Scope

### In Scope

- Chart scaffold: `Chart.yaml`, `values.yaml`, `values.schema.json`
- All templates: helpers, secrets, deployment, service, PXC CR, Valkey, HTTPRoute, Ingress,
  HPA, PDB, ServiceAccount, NOTES.txt
- Helm test hooks: MySQL connection, Valkey ping, Fleet healthcheck
- Unit tests for all templates (helm-unittest)
- helm-docs: `README.md.gotmpl`, annotated values, generated README
- Chart-testing CI values: `ci/default-values.yaml`, `ci/ha-values.yaml`
- Local validation: `make helm-test`, `make helm-ct-lint`, `make helm-docs-check`

### Out of Scope

- CI workflow changes (already done in IMPL-0001)
- PXC operator deployment
- ArgoCD Application manifests (documented in DESIGN-0001 for reference)
- End-to-end testing with a real Fleet + MySQL deployment

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its tasks
are checked off and its success criteria are met.

---

### Phase 1: Chart Scaffold

Create the chart directory structure and foundational files. No templates yet — just the
metadata, values, and schema that all subsequent phases build on.

#### Tasks

- [ ] Create `charts/fleetdm/Chart.yaml` with:
  - `apiVersion: v2`, `name: fleetdm`, `type: application`, `version: 0.1.0`
  - `appVersion: "4.82.0"` with Renovate annotation comment
  - Keywords, home URL, sources, maintainers
  - `dependencies: []` (no subcharts)
- [ ] Create `charts/fleetdm/values.yaml` with all value sections from DESIGN-0001:
  - Fleet app config (`replicaCount`, `image`, `fleet.*`)
  - Database (`database.*`)
  - Cache (`cache.*`)
  - PXC cluster (`pxc.*`)
  - Valkey (`valkey.*`)
  - HTTPRoute (`httpRoute.*`) — enabled by default
  - Ingress (`ingress.*`) — disabled by default
  - Standard Kubernetes (`serviceAccount`, `service`, `resources`, `autoscaling`,
    `podDisruptionBudget`, `nodeSelector`, `tolerations`, `affinity`)
  - All values annotated with `# --` comments for helm-docs
- [ ] Create `charts/fleetdm/values.schema.json` with constraints:
  - `database.name`, `database.username`, `database.passwordKey` — required non-empty
  - `pxc.size` — enum `[1, 3, 5, 7]`
  - `autoscaling.targetCPUUtilizationPercentage` — integer 1–100
  - `valkey.replicaCount` — minimum 1
- [ ] Verify `helm lint charts/fleetdm` passes with the scaffold

#### Success Criteria

- `helm lint charts/fleetdm` passes
- `values.schema.json` rejects invalid values (e.g., `pxc.size: 2`)
- All values have `# --` helm-docs annotations

---

### Phase 2: Helper Functions

Create `_helpers.tpl` with all standard and custom helper functions. These are dependencies
for every template in subsequent phases.

#### Tasks

- [ ] Create `charts/fleetdm/templates/_helpers.tpl` with standard helpers:
  - `fleetdm.name` — chart name
  - `fleetdm.fullname` — release-qualified name
  - `fleetdm.chart` — chart name + version
  - `fleetdm.labels` — standard Kubernetes labels
  - `fleetdm.selectorLabels` — selector subset of labels
  - `fleetdm.serviceAccountName` — conditional SA name
- [ ] Add custom helpers:
  - `fleetdm.image` — `image.repository:image.tag` falling back to `.Chart.AppVersion`
  - `fleetdm.mysqlSecretName` — `existingSecret` or chart-generated name
  - `fleetdm.redisSecretName` — `existingSecret` or chart-generated name
  - `fleetdm.pxcSecretName` — `existingSecret` or chart-generated name
  - `fleetdm.mysqlAddress` — explicit address, PXC-derived, or `fail`
  - `fleetdm.redisAddress` — explicit address, Valkey-derived, or `fail`
- [ ] Verify `helm template fleetdm charts/fleetdm` renders without errors (will produce
  empty output since no templates consume the helpers yet, but should not fail)

#### Success Criteria

- `helm template` does not error
- Helper `fail` messages are clear and actionable when tested with invalid value
  combinations (e.g., `pxc.enabled=false` + empty `database.address`)

---

### Phase 3: Core Templates

Implement the foundational templates that every deployment needs: secrets, service account,
deployment, and service.

#### Tasks

- [ ] Create `charts/fleetdm/templates/secret.yaml`:
  - MySQL secret (conditional on `database.existingSecret` being empty)
  - PXC credentials secret (conditional on `pxc.existingSecret` being empty, gated on
    `pxc.enabled`)
  - Redis/Valkey secret (conditional on `cache.usePassword` + `cache.existingSecret` empty)
  - All use `helm.sh/resource-policy: keep` annotation
  - All use `randAlphaNum 32 | b64enc` for generated passwords
- [ ] Create `charts/fleetdm/templates/serviceaccount.yaml`:
  - Conditional on `serviceAccount.create`
  - Supports `serviceAccount.annotations`
- [ ] Create `charts/fleetdm/templates/deployment.yaml`:
  - Replicas from `replicaCount` (omit when `autoscaling.enabled`)
  - Image from `fleetdm.image` helper
  - All Fleet env vars wired via helper functions (MySQL address/password, Redis
    address/password, TLS, logging, server URL, license key, auto-migrate)
  - Database connection pool env vars (`maxOpenConns`, `maxIdleConns`, `connMaxLifetime`)
  - `tmp` emptyDir volume mount for `readOnlyRootFilesystem: true`
  - Security context: `readOnlyRootFilesystem: true`, `runAsNonRoot: true`
  - Resource requests/limits from values
  - `nodeSelector`, `tolerations`, `affinity` from values
  - `imagePullSecrets` support
- [ ] Create `charts/fleetdm/templates/service.yaml`:
  - `ClusterIP` by default
  - Port from `service.port`
  - Selector labels from helper
- [ ] Create `charts/fleetdm/templates/NOTES.txt`:
  - Print access URL based on service type
  - Print reminder about PXC operator if `pxc.enabled`
  - Print `helm test` instructions
- [ ] Verify `helm template fleetdm charts/fleetdm` renders all core resources
- [ ] Run `make helm-lint` to validate

#### Success Criteria

- `helm template` renders Deployment, Service, ServiceAccount, and Secrets
- `helm lint charts/fleetdm` passes
- Secrets are skipped when `existingSecret` values are set
- Deployment env vars change correctly based on value combinations

---

### Phase 4: Extended Templates

Implement PXC cluster CR, Valkey StatefulSet, HTTPRoute, Ingress, HPA, and PDB.

#### Tasks

- [ ] Create `charts/fleetdm/templates/pxc-cluster.yaml`:
  - `PerconaXtraDBCluster` CR gated on `pxc.enabled`
  - ArgoCD `ServerSideApply=true` annotation
  - `secretsName` from `fleetdm.pxcSecretName`
  - PXC node config: `size`, `image`, `resources`, `storage`
  - HAProxy config: `enabled`, `size`, `resources`
  - Backup config: conditional on `pxc.backup.enabled`
- [ ] Create `charts/fleetdm/templates/valkey.yaml`:
  - StatefulSet + headless Service gated on `valkey.enabled`
  - Persistence: PVC when `valkey.persistence.enabled`, emptyDir otherwise
  - Password support: `--requirepass` when `cache.usePassword: true`
  - Resource requests/limits from values
- [ ] Create `charts/fleetdm/templates/httproute.yaml`:
  - `gateway.networking.k8s.io/v1 HTTPRoute` gated on `httpRoute.enabled`
  - `cert-manager.io/v1 Certificate` gated on `httpRoute.certManager.enabled`
  - `parentRefs` taken verbatim from values
  - Hostname from `httpRoute.hostname`
- [ ] Create `charts/fleetdm/templates/ingress.yaml`:
  - `networking.k8s.io/v1 Ingress` gated on `ingress.enabled`
  - `ingressClassName` from `ingress.className`
  - Annotations, hosts, TLS from values
- [ ] Create `charts/fleetdm/templates/hpa.yaml`:
  - `HorizontalPodAutoscaler` gated on `autoscaling.enabled`
  - `minReplicas`, `maxReplicas`, `targetCPUUtilizationPercentage` from values
- [ ] Create `charts/fleetdm/templates/pdb.yaml`:
  - `PodDisruptionBudget` gated on `podDisruptionBudget.enabled`
  - `minAvailable` from values
- [ ] Verify `helm template fleetdm charts/fleetdm` renders all resources with various
  value combinations (PXC on/off, Valkey on/off, HTTPRoute on/off, Ingress on/off)
- [ ] Run `make helm-lint` to validate

#### Success Criteria

- All extended templates render correctly when their feature flag is enabled
- All extended templates produce no output when their feature flag is disabled
- `helm lint charts/fleetdm` passes
- PXC CR includes ArgoCD server-side apply annotation
- Valkey StatefulSet uses emptyDir by default, PVC when persistence enabled

---

### Phase 5: Helm Test Hooks

Implement `helm test` pods that validate connectivity after install/upgrade.

#### Tasks

- [ ] Create `charts/fleetdm/templates/tests/test-mysql-connection.yaml`:
  - `helm.sh/hook: test` annotation
  - `mysql:8.0` image
  - Runs `SELECT 1` against MySQL address using Fleet credentials
  - `restartPolicy: Never`
- [ ] Create `charts/fleetdm/templates/tests/test-valkey-connection.yaml`:
  - `helm.sh/hook: test` annotation
  - Only rendered when cache is configured (`valkey.enabled` or `cache.address` set)
  - `valkey/valkey` image
  - Runs `PING` against cache address
  - Password support when `cache.usePassword: true`
- [ ] Create `charts/fleetdm/templates/tests/test-fleet-health.yaml`:
  - `helm.sh/hook: test` annotation with `hook-weight: "5"` (runs after connection tests)
  - `curlimages/curl` image
  - Hits `/healthz` on Fleet service, asserts HTTP 200
- [ ] Verify `helm template fleetdm charts/fleetdm --show-only templates/tests/` renders
  test pods

#### Success Criteria

- All three test hook templates render with correct annotations
- Test hooks use the same address/secret helpers as the deployment
- Valkey test hook is conditional on cache being configured
- Fleet health test runs after connection tests (hook-weight ordering)

---

### Phase 6: Unit Tests

Write comprehensive helm-unittest tests for all templates. Each test file covers the
enabled/disabled states and key value combinations described in DESIGN-0001.

#### Tasks

- [ ] Create `charts/fleetdm/tests/deployment_test.yaml`:
  - Renders a Deployment
  - `spec.replicas` matches `replicaCount`; absent when `autoscaling.enabled`
  - Image tag defaults to `appVersion`; explicit tag overrides
  - `FLEET_MYSQL_ADDRESS` from explicit address and from PXC derivation
  - `FLEET_MYSQL_PASSWORD` references generated vs existingSecret
  - `FLEET_REDIS_PASSWORD` absent when `cache.usePassword: false`; present when `true`
  - `FLEET_LICENSE_KEY` absent when unconfigured; present when `fleet.license.secretName`
    set
  - `tmp` emptyDir volume mounted
  - Security context: `readOnlyRootFilesystem`, `runAsNonRoot`
- [ ] Create `charts/fleetdm/tests/secret_test.yaml`:
  - MySQL secret rendered when `existingSecret` empty; skipped when set
  - PXC secret rendered when `pxc.enabled` and `existingSecret` empty; skipped otherwise
  - Redis secret rendered when `cache.usePassword` and `existingSecret` empty
  - All secrets have `helm.sh/resource-policy: keep`
- [ ] Create `charts/fleetdm/tests/pxc_cluster_test.yaml`:
  - Renders when `pxc.enabled: true`; no output when `false`
  - `metadata.name` matches `pxc.clusterName`
  - `spec.pxc.size` matches value
  - `spec.secretsName` derived vs existingSecret
  - HAProxy enabled by default
  - Backup absent when disabled; present with schedule when enabled
- [ ] Create `charts/fleetdm/tests/httproute_test.yaml`:
  - No output when `httpRoute.enabled: false`
  - HTTPRoute only when `certManager.enabled: false`
  - Both Certificate + HTTPRoute when both enabled
  - Hostname and parentRefs match values
- [ ] Create `charts/fleetdm/tests/ingress_test.yaml`:
  - No output when `ingress.enabled: false`
  - Renders Ingress when enabled
  - `ingressClassName`, annotations, hosts, TLS from values
- [ ] Create `charts/fleetdm/tests/hpa_test.yaml`:
  - No output when `autoscaling.enabled: false`
  - Renders HPA when enabled
  - `minReplicas`, `maxReplicas`, CPU target match values
- [ ] Create `charts/fleetdm/tests/pdb_test.yaml`:
  - No output when `podDisruptionBudget.enabled: false`
  - Renders PDB when enabled
  - `minAvailable` matches value
- [ ] Create `charts/fleetdm/tests/service_test.yaml`:
  - Renders Service
  - Port matches `service.port`
  - Type matches `service.type`
- [ ] Create `charts/fleetdm/tests/serviceaccount_test.yaml`:
  - Renders when `serviceAccount.create: true`; skipped when `false`
  - Annotations from values
- [ ] Create `charts/fleetdm/tests/valkey_test.yaml`:
  - No output when `valkey.enabled: false`
  - Renders StatefulSet + Service when enabled
  - Persistence: emptyDir default, PVC when `persistence.enabled`
  - Password arg present when `cache.usePassword: true`
- [ ] Run `make helm-unittest` and verify all tests pass

#### Success Criteria

- `make helm-unittest` passes with zero failures
- Every template has at least one test for enabled and disabled states
- Key value combinations (existingSecret, PXC derivation, autoscaling interaction) are
  covered

---

### Phase 7: Documentation

Annotate values for helm-docs, create the README template, and generate the chart README.

#### Tasks

- [ ] Verify all values in `charts/fleetdm/values.yaml` have `# --` annotations (should
  already be done in Phase 1, but verify completeness)
- [ ] Create `charts/fleetdm/README.md.gotmpl` with:
  - Chart name, description, version/type/appVersion badges
  - Prerequisites section (Kubernetes, Helm, PXC Operator, Gateway API CRDs, cert-manager)
  - Installation instructions
  - Secret management section (existingSecret pattern)
  - Values table (auto-generated by helm-docs)
- [ ] Run `make helm-docs` to generate `charts/fleetdm/README.md`
- [ ] Run `make helm-docs-check` to verify docs are in sync
- [ ] Verify generated README looks correct and all values are documented

#### Success Criteria

- `make helm-docs` generates a complete README
- `make helm-docs-check` passes (no diff)
- All values appear in the generated values table with descriptions

---

### Phase 8: Chart Testing Values and Validation

Write CI test values and validate the full chart with lint and local install testing.

#### Tasks

- [ ] Create `charts/fleetdm/ci/default-values.yaml`:
  - PXC disabled, Valkey disabled
  - Stub `database.address` and `database.existingSecret`
  - Stub `cache.address`
  - HTTPRoute disabled (Gateway API CRDs not in Kind by default)
  - Ingress disabled
  - Minimal resource config for Kind
- [ ] Create `charts/fleetdm/ci/ha-values.yaml`:
  - PXC disabled (no operator in Kind)
  - Valkey enabled with persistence disabled
  - Stub `database.address` and `database.existingSecret`
  - Autoscaling enabled
  - PDB enabled
  - HTTPRoute disabled (no Gateway API CRDs in Kind)
  - Ingress enabled to exercise that code path
- [ ] Run `make helm-lint` and verify it passes
- [ ] Run `make helm-unittest` and verify all tests pass
- [ ] Run `make helm-ct-lint` and verify it passes
- [ ] Run `make helm-docs-check` and verify it passes
- [ ] Run `make helm-template-ci` and verify all CI value combinations render cleanly

#### Success Criteria

- `make helm-test` passes (lint + unittest)
- `make helm-ct-lint` passes
- `make helm-docs-check` passes
- `make helm-template-ci` renders without errors for both CI values files
- `make ci` passes end-to-end

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `charts/fleetdm/Chart.yaml` | Create | Chart metadata with Renovate appVersion annotation |
| `charts/fleetdm/values.yaml` | Create | All chart values with helm-docs annotations |
| `charts/fleetdm/values.schema.json` | Create | JSON Schema validation for values |
| `charts/fleetdm/templates/_helpers.tpl` | Create | Standard + custom helper functions |
| `charts/fleetdm/templates/secret.yaml` | Create | Conditional MySQL, PXC, Redis secrets |
| `charts/fleetdm/templates/serviceaccount.yaml` | Create | Conditional ServiceAccount |
| `charts/fleetdm/templates/deployment.yaml` | Create | Fleet Deployment with env wiring |
| `charts/fleetdm/templates/service.yaml` | Create | ClusterIP Service |
| `charts/fleetdm/templates/NOTES.txt` | Create | Post-install instructions |
| `charts/fleetdm/templates/pxc-cluster.yaml` | Create | PerconaXtraDBCluster CR |
| `charts/fleetdm/templates/valkey.yaml` | Create | Valkey StatefulSet + headless Service |
| `charts/fleetdm/templates/httproute.yaml` | Create | HTTPRoute + optional Certificate |
| `charts/fleetdm/templates/ingress.yaml` | Create | Classic Ingress (disabled by default) |
| `charts/fleetdm/templates/hpa.yaml` | Create | HorizontalPodAutoscaler |
| `charts/fleetdm/templates/pdb.yaml` | Create | PodDisruptionBudget |
| `charts/fleetdm/templates/tests/test-mysql-connection.yaml` | Create | MySQL SELECT 1 test |
| `charts/fleetdm/templates/tests/test-valkey-connection.yaml` | Create | Valkey PING test |
| `charts/fleetdm/templates/tests/test-fleet-health.yaml` | Create | Fleet /healthz test |
| `charts/fleetdm/tests/deployment_test.yaml` | Create | Deployment unit tests |
| `charts/fleetdm/tests/secret_test.yaml` | Create | Secret unit tests |
| `charts/fleetdm/tests/pxc_cluster_test.yaml` | Create | PXC CR unit tests |
| `charts/fleetdm/tests/httproute_test.yaml` | Create | HTTPRoute unit tests |
| `charts/fleetdm/tests/ingress_test.yaml` | Create | Ingress unit tests |
| `charts/fleetdm/tests/hpa_test.yaml` | Create | HPA unit tests |
| `charts/fleetdm/tests/pdb_test.yaml` | Create | PDB unit tests |
| `charts/fleetdm/tests/service_test.yaml` | Create | Service unit tests |
| `charts/fleetdm/tests/serviceaccount_test.yaml` | Create | ServiceAccount unit tests |
| `charts/fleetdm/tests/valkey_test.yaml` | Create | Valkey unit tests |
| `charts/fleetdm/README.md.gotmpl` | Create | helm-docs template |
| `charts/fleetdm/README.md` | Create | Generated README (helm-docs output) |
| `charts/fleetdm/ci/default-values.yaml` | Create | Minimal CI test values |
| `charts/fleetdm/ci/ha-values.yaml` | Create | HA CI test values |

## Testing Plan

- [ ] `make helm-lint` passes
- [ ] `make helm-unittest` passes with all tests green
- [ ] `make helm-ct-lint` passes
- [ ] `make helm-docs-check` passes (no stale docs)
- [ ] `make helm-template` renders all resources with default values
- [ ] `make helm-template-ci` renders cleanly for both CI values files
- [ ] `make ci` passes end-to-end
- [ ] `helm template` with `pxc.enabled=false` + empty `database.address` produces a clear
  `fail` error message
- [ ] `helm template` with `valkey.enabled=false` + empty `cache.address` produces a clear
  `fail` error message

## Dependencies

- IMPL-0001 (Repository Scaffold) must be complete — provides CI workflow, Makefile, ct.yaml
- helm-unittest plugin installed (`helm plugin install https://github.com/helm-unittest/helm-unittest`)

## Open Questions

- **Fleet env var names:** The design doc references env vars like `FLEET_MYSQL_ADDRESS`,
  `FLEET_REDIS_ADDRESS`, etc. These need to be verified against the Fleet 4.82.0 source to
  ensure correctness. The upstream Fleet docs or `fleet serve --help` output should be the
  source of truth for env var names and any additional required vars.
- **PXC CR API version:** The design references `PerconaXtraDBCluster` but does not specify
  the `apiVersion`. PXC operator v1.19.0 uses `pxc.percona.com/v1`. This needs to be
  confirmed against the target operator version.
- **Valkey image tag:** The design uses `7.2` but the latest Valkey stable may be newer.
  Should we pin the latest stable at chart creation time and let Renovate handle updates?
- **HTTPRoute enabled by default:** DESIGN-0001 says HTTPRoute is enabled by default, but
  the FLEETMD.md source has `httpRoute.enabled: false`. The design doc decision takes
  precedence, but this means `helm install` with zero value overrides will require Gateway
  API CRDs. Should `httpRoute.parentRefs` default to empty list to avoid rendering an
  invalid HTTPRoute, or should the template `fail` if parentRefs is empty?
- **Security context UID/GID:** The design specifies `runAsNonRoot: true` and
  `readOnlyRootFilesystem: true` but does not specify `runAsUser`/`runAsGroup`. The Fleet
  container image may expect a specific UID. Needs verification against the `fleetdm/fleet`
  Docker image.
- **Database connection pool env vars:** The design includes `maxOpenConns`, `maxIdleConns`,
  `connMaxLifetime` in values but doesn't map them to Fleet env vars in the deployment
  template. Need to verify the exact Fleet env var names for these settings.

## References

- [DESIGN-0001: FleetDM Helm Chart](../design/0001-fleetdm-helm-chart.md)
- [RFC-0001: Helm Charts Repository Layout and Conventions](../rfc/0001-helm-charts-repository-layout-and-conventions.md)
- [IMPL-0001: Repository Scaffold](../impl/0001-repository-scaffold.md)
- [FleetDM Configuration](https://fleetdm.com/docs/deploying/configuration)
- [FleetDM Docker Image](https://hub.docker.com/r/fleetdm/fleet)
- [PXC Operator CRD Reference](https://docs.percona.com/percona-operator-for-mysql/pxc/operator.html)
