---
id: RFC-0001
title: "Helm Charts Repository Layout and Conventions"
status: Draft
author: Donald Gifford
created: 2026-03-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# RFC 0001: Helm Charts Repository Layout and Conventions

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-03-15

## Summary

Establish a public Helm charts monorepo for charts that fix or improve upon upstream
offerings. The repo uses chart-testing for PR validation, chart-releaser for GitHub Pages
hosting, Renovate for automated appVersion tracking, and helm-docs for generated README
files.

## Problem Statement

Upstream Helm charts frequently break in ways that block production deployments:

- **FleetDM** — depends on Bitnami MySQL and Redis subcharts that break on every major
  Bitnami version bump. The subchart pinning is fragile, and the upstream chart has gone
  months without fixes for known issues.
- **General Bitnami subchart pattern** — many community charts pull in Bitnami common
  library or database subcharts that introduce breaking changes in minor versions, require
  coordinated version bumps, and carry unnecessary complexity (dozens of values for
  features never used).

These charts lack opinionated defaults for production use (no PDB, no HPA, no Gateway API
support, no existingSecret patterns). There is no centralized place to maintain improved
alternatives with automated testing, version tracking, and release pipelines.

### Scope

This repo targets charts where the upstream offering is broken, abandoned, or missing
production-ready defaults. The initial chart is FleetDM (see
[DESIGN-0001](../design/0001-fleetdm-helm-chart.md)). Additional charts will be added as
needed — this is not a general-purpose chart registry.

## Proposed Solution

A monorepo under `charts/` where each chart is independently versioned, tested, and
released. The repo relies on three key integrations:

1. **Chart Releaser** (`helm/chart-releaser-action`) packages charts, creates GitHub
   releases per chart version, and maintains a `gh-pages` branch as the Helm repo index.
2. **Chart Testing** (`helm/chart-testing-action`) detects changed charts on PRs, lints
   them, and installs them into a Kind cluster.
3. **Renovate** watches `Chart.yaml` `appVersion` fields via regex custom managers and
   opens PRs to bump versions from upstream sources.

Users add the repo with:

```sh
helm repo add donaldgifford https://donaldgifford.github.io/helm-charts
```

## Design

### Repository Structure

```
helm-charts/
├── .github/
│   ├── workflows/
│   │   ├── lint-test.yaml          # PR: ct lint + ct install (kind cluster)
│   │   ├── release.yaml            # on merge: chart-releaser-action
│   │   └── renovate-validate.yaml  # validate renovate config on PR
│   ├── CODEOWNERS
│   └── renovate.json5
├── charts/
│   ├── <app-name>/
│   │   ├── Chart.yaml
│   │   ├── Chart.lock
│   │   ├── values.yaml
│   │   ├── templates/
│   │   │   ├── _helpers.tpl
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── serviceaccount.yaml
│   │   │   └── tests/
│   │   │       └── test-connection.yaml
│   │   ├── ci/
│   │   │   └── test-values.yaml    # values for ct install
│   │   └── README.md               # helm-docs generated
│   └── <another-app>/
│       └── ...
├── ct.yaml
├── cr.yaml                         # chart-releaser config (optional)
├── .helmignore
├── LICENSE
└── README.md
```

### Renovate Configuration for appVersion Tracking

Each `Chart.yaml` annotates the appVersion for Renovate to track:

```yaml
apiVersion: v2
name: some-app
version: 0.1.0
appVersion: "1.2.3" # renovate: datasource=docker depName=ghcr.io/org/some-app
```

The `renovate.json5` uses a custom regex manager to match `appVersion` annotations:

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: ["config:recommended"],
  packageRules: [
    {
      matchManagers: ["helmv3"],
      matchFileNames: ["charts/**"],
      automerge: false,
      additionalBranchPrefix: "{{packageFileDir}}/",
      commitMessagePrefix: "chart({{packageFileDir}}):",
    },
  ],
  customManagers: [
    {
      customType: "regex",
      fileMatch: ["charts/.+/Chart\\.yaml$"],
      matchStrings: [
        "appVersion:\\s*[\"']?(?<currentValue>[^\"'\\s]+)[\"']?\\s*#\\s*renovate:\\s*datasource=(?<datasource>[^\\s]+)\\s+depName=(?<depName>[^\\s]+)",
      ],
      versioningScheme: "semver",
    },
  ],
}
```

**Complexity note:** The regex custom manager is powerful but fragile — a stray whitespace
change in the `Chart.yaml` annotation can break matching silently. Mitigations: (1) the
`renovate-validate.yaml` workflow validates the Renovate config on every PR, (2) Renovate's
dependency dashboard surfaces charts that stop receiving updates, and (3) each chart's
`Chart.yaml` should include a comment documenting the exact annotation format.

### CI Workflows

**`lint-test.yaml` (on PR):**

1. `helm/chart-testing-action` with `ct lint-and-install`
2. Spins up a Kind cluster, installs changed charts with each `ci/*.yaml` values file
3. `helm-docs` diff check — fail if README is stale
4. Trivy scan against rendered manifests (HIGH/CRITICAL) — catches misconfigurations in
   templates, not just filesystem vulnerabilities

**`release.yaml` (on push to main):**

1. `helm/chart-releaser-action` — detects version bumps, packages, publishes to `gh-pages`

### Conventions

- **Multiple test values per chart:** One `ci/` directory per chart with multiple test
  values files (`ci/default-values.yaml`, `ci/full-values.yaml`) so `ct install` runs
  multiple scenarios.
- **Common helper patterns:** Standardize labels, selectors, and naming across all charts
  via `_helpers.tpl`. Duplicate shared snippets across charts rather than introducing a
  library chart — the indirection and coupling of library charts outweighs the DRY benefit.
- **Commit Chart.lock:** Pin dependency versions by committing `Chart.lock`.
- **Conventional commits scoped per chart:** `chart(technitium): bump appVersion to 1.2.3`
- **helm-docs:** Generate `README.md` per chart from a `README.md.gotmpl` template and
  values file comments. Enforce in CI so docs never drift.

## Alternatives Considered

- **OCI registry hosting:** Push charts to an OCI registry (GHCR, ECR) instead of GitHub
  Pages. Rejected because GitHub Pages + chart-releaser is the standard for public repos,
  requires no external infrastructure, and integrates directly with `helmCharts:` blocks in
  kustomization.yaml for ArgoCD deployments. OCI registries require additional
  authentication setup for consumers and have less mature tooling for public discovery.
- **Single chart per repo:** Separate repositories per chart. Rejected because a monorepo
  simplifies shared CI (one workflow set, one Renovate config), consistent conventions, and
  reduces maintenance overhead. The trade-off is that all charts share a CI pipeline, but
  chart-testing's changed-chart detection makes this efficient.

## Implementation Phases

### Phase 1: Repository Scaffold

Set up the repo structure, `ct.yaml`, CI workflows for lint-test and release, Renovate
configuration, and helm-docs integration. This phase is complete when `ct lint` passes with
no charts present and the release workflow is wired up.

### Phase 2: First Chart (FleetDM)

Add the FleetDM chart following all conventions (annotated `Chart.yaml`, `ci/` test values,
`README.md.gotmpl`, helm-unittest tests). Validate the full pipeline end-to-end: PR
triggers lint-test, merge triggers chart-releaser, Renovate opens an appVersion bump PR.
See [DESIGN-0001](../design/0001-fleetdm-helm-chart.md) for the chart design.

### Phase 3: Ongoing

Add additional charts as needed. Renovate handles version bumps. Chart-releaser handles
releases.

## Rollback Strategy

- **Bad chart release:** Chart-releaser creates GitHub Releases per chart version. A bad
  release can be deleted from GitHub Releases, and `cr index` re-run to regenerate the
  `gh-pages` index without that version. Users on the bad version can `helm rollback` to
  their previous release.
- **CI toolchain breakage:** All CI tooling is pinned to specific action versions in
  workflows (e.g., `chart-testing-action@v2.8.0`, `chart-releaser-action@v1.6.0`).
  Rollback by reverting the version bump PR. Renovate config changes are validated by
  `renovate-validate.yaml` before merge.
- **Chart deprecation:** Add `deprecated: true` to `Chart.yaml`, bump the chart version to
  trigger a final release with the deprecation notice, and document the migration path in
  the chart README.

## Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Renovate regex manager breaks on Chart.yaml format changes | Missed version bumps | Low | Pin the regex pattern, add Renovate config validation workflow, monitor dependency dashboard for stale charts |
| Kind cluster tests are slow or flaky | Delayed PRs | Medium | Use `ci/` values that minimize resource requirements; skip ct install when no charts changed |
| Chart-releaser fails on concurrent merges | Missed releases | Low | Run release workflow only on main; chart-releaser is idempotent with `skip_existing: true` |
| Chart-releaser-action deprecation or API change | Broken release pipeline | Low | Pin action versions, monitor upstream releases, OCI registry is a viable fallback if GitHub Pages hosting breaks |
| Dependency conflicts between charts in monorepo | Shared CI breakage | Low | Each chart is independently versioned with no shared dependencies; chart-testing only lints/installs changed charts |

## Success Criteria

- Every chart PR is automatically linted (`ct lint` passes), unit-tested (`helm unittest`
  passes), and install-tested in Kind (`ct install` succeeds with all `ci/` values files)
- Chart releases are fully automated on merge to main — no manual `helm package` or
  `cr upload` steps required
- appVersion bumps are tracked and proposed automatically by Renovate within 24 hours of
  an upstream release
- Chart READMEs are always in sync with values — `helm-docs` diff check fails the PR if
  stale
- Rollback of a bad chart release can be completed in under 15 minutes by deleting the
  GitHub Release and re-indexing

## Resolved Questions

- **Chart naming convention:** Use the original upstream name (e.g., `fleetdm`). Charts
  are served from our own GitHub Pages URL, so there is no collision with upstream repos.
- **Chart deprecation workflow:** Mark `deprecated: true` in `Chart.yaml`, bump the chart
  version, and publish a final release with migration guidance in the README. Do not remove
  the chart directory — existing users need the index entry to resolve.
- **Renovate vs Dependabot:** Standardize on Renovate for all automation (appVersion
  tracking, GitHub Actions version bumps, dependency management). Remove the
  forge-generated `.github/dependabot.yml`.
- **Security scanning:** Yes — add Trivy manifest scanning to the lint-test workflow.
  Render templates and scan the output for misconfigurations (HIGH/CRITICAL).
- **Library chart:** No library charts. Duplicate shared helpers across charts. The
  indirection and coupling of library charts outweighs the DRY benefit for this repo's
  scale.

## References

- [helm/chart-releaser-action](https://github.com/helm/chart-releaser-action)
- [helm/chart-testing-action](https://github.com/helm/chart-testing-action)
- [helm-unittest](https://github.com/helm-unittest/helm-unittest)
- [helm-docs](https://github.com/norwoodj/helm-docs)
- [Renovate Helm Manager](https://docs.renovatebot.com/modules/manager/helmv3/)
- [DESIGN-0001: FleetDM Helm Chart](../design/0001-fleetdm-helm-chart.md)
