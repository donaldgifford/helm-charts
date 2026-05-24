# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Helm chart repository for Kubernetes applications. Charts live under `charts/` and are released to GitHub Pages via `helm/chart-releaser-action`. The repo was scaffolded from a `forge` blueprint (`go-ext`); config files managed by forge should not be manually edited (see `.forge-lock.yaml` for the list).

## Tool Versions

All tools are managed via **mise** (`mise.toml`). Key versions: Helm 3.19.0, helm-ct 3.14.0, helm-docs 1.14.2, helm-cr 1.8.1, helm-diff 3.15.0. Run `mise install` to set up the environment.

## Common Commands

```
make helm-lint              # Lint all charts
make helm-unittest          # Run helm-unittest plugin tests
make helm-test              # Lint + unit tests combined
make helm-template          # Render templates with default values
make helm-template-ci       # Render templates with CI values
make helm-docs              # Generate chart READMEs with helm-docs
make helm-docs-check        # Check that helm-docs are up to date
make helm-ct-lint           # chart-testing lint (uses ct.yaml config)
make helm-ct-install        # Install and test in kind cluster
make helm-package           # Package charts to .tgz
make helm-diff-check        # Show diff (RELEASE= CHART= required)
make check                  # Quick pre-commit (lint + unittest)
make ci                     # Full CI pipeline (lint + unittest + ct lint)
```

All helm-* targets skip gracefully when no charts exist under `charts/`.

## CI Pipeline

GitHub Actions CI (`.github/workflows/ci.yml`) runs on PRs to `main`:
- **Helm Lint** — `helm lint` on all charts (skips if no charts)
- **Helm Unit Tests** — `helm-unittest` plugin (skips if no tests)
- **Helm Docs Check** — `helm-docs` diff to catch stale READMEs
- **Security** — Trivy filesystem scan + rendered manifest scan (HIGH/CRITICAL)
- **Renovate Validate** — validates `renovate.json5` config
- **Chart Testing** — `ct lint` always; `ct install` in Kind only when charts change

Chart releases are triggered manually via `workflow_dispatch` on `chart-release.yml`.

## Version Tracking

Renovate (`renovate.json5`) tracks `appVersion` in `Chart.yaml` via regex custom manager. Each chart annotates its appVersion with a comment on the line above:
```yaml
# renovate: image=fleetdm/fleet
appVersion: "4.82.0"
```

## Chart Testing Config

`ct.yaml` configures chart-testing: charts dir is `charts/`, target branch is `main`. Charts have a separate yamllint config at `charts/.yamllint.yml` (150 char line limit, `templates/` dirs ignored).

## Conventions

- YAML indentation: 2 spaces, `document-start: present` required (see `.yamllint.yml`)
- Helm chart unit tests use the `helm-unittest` plugin
- Conventional commits scoped per chart: `chart(fleetdm): bump appVersion to 1.2.3`
- Documentation managed with `docz` CLI (`.docz.yaml`); doc types: RFC, ADR, Design, Impl, Plan, Investigation
- `values.schema.json` for input validation (required fields, enum constraints)
- `Chart.yaml` and `values.yaml` must start with `---` (yamllint `document-start: present`)
- No library charts — duplicate shared helpers across charts
- Forge-managed files (listed in `.forge-lock.yaml`) should not be edited directly

## Working Patterns

- **Minimal scope, defer broader fixes**: When a bug is reported, scope the fix to the actual lived issue. Broader idiomatic refactors get tracked in a GitHub issue (e.g., #17) rather than expanded into the active PR. Validated mid-IMPL-0003 — the Redis secret regeneration was fixed in isolation while the broader `secret.create`/`secret.name` rewrite for both MySQL and Redis was deferred.
- **Investigation → Impl doc → Code → PR**: For non-trivial changes, use the docz lifecycle (`docz new investigation`, `docz new impl`) before code. The impl doc should have a Decisions table at the top capturing user-answered Q/A so the rationale survives the PR.
- **Homelab is the only consumer**: Breaking-change coordination happens via the homelab values overlay only. Backwards-compat shims and migration scripts are usually unnecessary; just bump the chart version and document the upgrade path in the impl doc.
- **Helm `lookup` is unreliable under `helm template`**: ArgoCD without `--enable-helm-lookup`, kustomize `helmCharts`, and helmfile diff all return empty from `lookup`. Don't use `lookup → fallback randAlphaNum` for secret generation — it regenerates on every render. Prefer requiring `existingSecret` and failing closed in the helper. (See INV-0001 in `docs/investigation/`.)

## Charts

### chartdb
ChartDB Helm chart — a slim stateless wrapper around the upstream `ghcr.io/chartdb/chartdb` image.
- Single Deployment + ClusterIP Service. No backing services (no Postgres, Redis, ClickHouse, S3 — ChartDB is purely browser-side).
- All app-shaped values namespaced under `chartdb.*`; only `nameOverride`/`fullnameOverride` at top level.
- Non-root nginx (uid 101) + `capabilities: drop ALL, add NET_BIND_SERVICE` so we can bind `:80` while staying PSS-Restricted-compliant.
- `readOnlyRootFilesystem: true` with `emptyDir` mounts over `/etc/nginx/conf.d/`, `/var/cache/nginx/`, `/var/run/`, `/tmp/`. A `seed-nginx-template` init container copies upstream's `default.conf.template` from the image into the shared `nginx-conf-d` emptyDir so the main container's envsubst entrypoint can render `default.conf` against it (mounting emptyDir over `/etc/nginx/conf.d/` would otherwise mask the template baked into the image). Validated end-to-end in Kind during IMPL-0004 Phase 2.
- `OPENAI_API_KEY` (for ChartDB's AI features) is `existingSecret`-only — helper `chartdb.openaiSecretName` fails closed when `chartdb.openai.enabled: true` without a Secret name (per INV-0001 pattern).
- Classic `Ingress` (default-on, guarded on non-empty `hosts`) and vanilla Gateway API `HTTPRoute` (default-off, guarded on non-empty `parentRefs`) under `chartdb.ingress.*` and `chartdb.httpRoute.*`.
- Replicas only — no HPA/KEDA/VPA/PDB in v0.1 (init-container approach to drop NET_BIND_SERVICE is tracked as a v0.2 Future Consideration in DESIGN-0003).
- `ct install` in Kind is feasible (no external deps); planned for IMPL-0004 Phase 5.

### fleetdm
FleetDM device management chart with embedded MySQL StatefulSet and optional Valkey cache.
- Embedded MySQL StatefulSet (replaced PXC operator in 0.4.0; PXC Galera doesn't support `LOCK=NONE` migrations)
- MySQL Secret: chart generates by default with `lookup`+`randAlphaNum` and `helm.sh/resource-policy: keep` (overridable via `database.existingSecret`)
- **Cache (Valkey/Redis) Secret: chart never generates** — `cache.existingSecret` is required when `cache.usePassword: true`. Helper `fleetdm.redisSecretName` fails closed with actionable error. Reason: `lookup` returns empty under `helm template` (ArgoCD without `--enable-helm-lookup`, kustomize, helmfile), causing password regeneration drift (INV-0001 / IMPL-0003)
- Gateway API `HTTPRoute` enabled by default (guarded on non-empty `parentRefs`)
- Classic `Ingress` supported but disabled by default
- Fleet image runs as uid=100/gid=101, `readOnlyRootFilesystem: true`
- Helper `fail` pattern: `mysqlAddress` and `redisAddress` fail with actionable messages when neither address nor embedded service is configured
- 10 unit test suites (82 tests) in `charts/fleetdm/tests/`
- CI values: `ci/default-values.yaml` (minimal, `cache.usePassword: false`), `ci/ha-values.yaml` (HA config, sets `cache.existingSecret: fleet-redis-stub`)
- Issue #17 tracks broader idiomatic Helm `secret.create` / `secret.name` rewrite for both DB and cache
