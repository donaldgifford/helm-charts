---
id: IMPL-0001
title: "Repository Scaffold"
status: Complete
author: Donald Gifford
created: 2026-03-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0001: Repository Scaffold

**Status:** Complete
**Author:** Donald Gifford
**Date:** 2026-03-15

## Objective

Set up the helm-charts monorepo infrastructure so that adding a new chart requires only
dropping files into `charts/<name>/` and pushing a PR. Everything else — linting, testing,
docs validation, security scanning, and release — should be automated.

**Implements:** [RFC-0001](../rfc/0001-helm-charts-repository-layout-and-conventions.md)

## Scope

### In Scope

- Clean up forge Go artifacts (workflows, config files, dependabot, labeler, gitignore)
- Rewrite CI workflow for Helm charts (lint, unittest, ct, Trivy manifest scan, helm-docs)
- Update chart-release workflow
- Set up Renovate configuration for appVersion tracking
- Update labeler for chart-oriented PRs
- Update `.gitignore` for Helm artifacts
- Update `mise.toml` to remove Go-only tools
- Validate `make ci` passes with no charts present

### Out of Scope

- Creating any charts (that's DESIGN-0001 / IMPL for FleetDM)
- Setting up the `gh-pages` branch (done once manually or on first release)
- Renovate bot installation on the GitHub repo (admin action)

## Implementation Phases

---

### Phase 1: Remove Go Artifacts

Clean up files left over from the `go-ext` forge blueprint that don't apply to a Helm
charts repo.

#### Tasks

- [x] Delete `.github/dependabot.yml` — replaced by Renovate (per RFC-0001 resolved
  questions)
- [x] Delete `.github/licenses-csv.tpl` — Go license tooling, not applicable
- [x] Delete `.github/workflows/ci.yml` — will be replaced by a new Helm-oriented workflow
- [x] Delete `.github/workflows/pr-labels.yml` — semver label enforcement is for Go binary
  releases, not chart versioning
- [x] Delete `scripts/labels.sh` — paired with pr-labels.yml for creating GitHub labels
- [x] Delete `.codecov.yml` — Go coverage config, not applicable
- [x] Update `.gitignore` — remove Go-specific entries, add Helm artifacts (`*.tgz`,
  `.cr-release-packages/`, `.cr-index/`)
- [x] Update `mise.toml` — remove `go`, `golangci-lint`, `goreleaser`, and
  `go:github.com/goreleaser/chglog/cmd/chglog`. Keep `helm-unittest` plugin reference in a
  comment or add to mise if supported
- [x] Update `.github/labeler.yml` — remove `go`, `docker`, `dependencies` (go.mod)
  labels; add `helm` label for `charts/**` changes
- [x] Remove `repo` label entries referencing deleted files (`.golangci.yml`,
  `.goreleaser.yaml`, `changelog.yaml`)

#### Success Criteria

- No references to Go, goreleaser, dependabot, or codecov remain in tracked files
- `mise install` succeeds without Go-related errors
- `.gitignore` covers Helm packaging artifacts

---

### Phase 2: CI Workflow

Replace the Go-oriented CI with a Helm-focused pipeline matching the RFC spec.

#### Tasks

- [x] Create `.github/workflows/ci.yml` with the following jobs:
  - **lint** — `helm lint charts/*`
  - **helm-unittest** — run `helm-unittest` on all charts (skip gracefully if no charts
    exist)
  - **helm-docs-check** — `helm-docs --dry-run` diff to catch stale READMEs
  - **security** — Trivy filesystem scan (keep existing) + Trivy scan on rendered
    manifests via `helm template` output
  - **chart-test** — `ct lint` always; `ct list-changed` to gate Kind cluster creation and
    `ct install` (only when charts change)
- [x] Update `chart-release.yml` — verify it works as-is (looks correct already) or adjust
  if needed
- [x] Ensure all workflows use pinned action versions with SHA or tag

#### Success Criteria

- `ci.yml` passes on a PR with no charts (lint/unittest/docs jobs skip gracefully or
  succeed with no-op)
- `ci.yml` passes on a PR that adds a chart with `ci/` test values
- Chart-release workflow packages and publishes on manual dispatch

---

### Phase 3: Renovate Configuration

Set up Renovate to track appVersion bumps and GitHub Actions versions.

#### Tasks

- [x] Create `renovate.json5` at repo root with:
  - `extends: ["config:recommended"]`
  - `packageRules` for `helmv3` manager scoped to `charts/**`
  - `customManagers` regex manager for `appVersion` annotation tracking in `Chart.yaml`
  - GitHub Actions version tracking (replaces Dependabot's `github-actions` ecosystem)
- [x] Add `renovate-validate` job to CI workflow or as a separate workflow — validate
  Renovate config on PRs that touch `renovate.json5`

#### Success Criteria

- Renovate config passes `renovate-config-validator` locally
- Dashboard issue appears in the repo after Renovate bot is enabled (admin step, out of
  scope)

---

### Phase 4: Polish and Validation

Final cleanup and end-to-end validation.

#### Tasks

- [x] Run `make ci` and verify it passes with no charts
- [x] Run `make helm-docs` and verify it completes (no-op with no charts)
- [x] Verify `ct lint --config ct.yaml --all` passes with no charts
- [x] Review all remaining forge-managed files in `.forge-lock.yaml` — confirm none
  reference deleted files or broken paths
- [x] Update `CLAUDE.md` to reflect the cleaned-up repo (remove Go commands section, update
  CI pipeline description)
- [x] Update repo `README.md` with Helm repo usage instructions (`helm repo add ...`)

#### Success Criteria

- `make ci` passes cleanly
- `make helm-lint`, `make helm-unittest`, `make helm-docs` all succeed or no-op gracefully
- README shows how to add the Helm repo

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `.github/dependabot.yml` | Delete | Replaced by Renovate |
| `.github/licenses-csv.tpl` | Delete | Go license tooling |
| `.github/workflows/ci.yml` | Rewrite | Helm-oriented CI pipeline |
| `.github/workflows/chart-release.yml` | Review | Verify correct, minor tweaks if needed |
| `.github/labeler.yml` | Modify | Remove Go labels, add `helm` label |
| `.codecov.yml` | Delete | Go coverage, not applicable |
| `.github/workflows/pr-labels.yml` | Delete | Semver label enforcement for Go releases |
| `scripts/labels.sh` | Delete | Paired with pr-labels.yml |
| `.gitignore` | Modify | Remove Go entries, add Helm artifacts |
| `mise.toml` | Modify | Remove Go-only tools |
| `renovate.json5` | Create | Renovate config for appVersion + GH Actions |
| `CLAUDE.md` | Modify | Remove Go commands, update CI description |
| `README.md` | Modify | Add Helm repo usage instructions |

## Testing Plan

- [x] `make ci` passes with no charts present
- [x] `make helm-lint` / `make helm-unittest` skip gracefully with no charts
- [x] `ct lint --config ct.yaml --all` exits 0 with no charts
- [ ] Push a test PR to verify CI workflow triggers and all jobs pass
- [ ] `renovate-config-validator` passes on `renovate.json5`

## Dependencies

- Renovate bot must be installed on the GitHub repo (admin action, out of scope for this
  impl)
- `gh-pages` branch must exist for chart-releaser to publish (created manually once or
  on first release)

## Resolved Questions

- **`pr-labels.yml` and `scripts/labels.sh`:** Remove both. The semver label enforcement
  is for Go binary releases. Chart versioning is driven by `version` in `Chart.yaml`, not
  PR labels. The labels script is paired with the workflow and has no use without it.

## References

- [RFC-0001: Helm Charts Repository Layout and Conventions](../rfc/0001-helm-charts-repository-layout-and-conventions.md)
- [DESIGN-0001: FleetDM Helm Chart](../design/0001-fleetdm-helm-chart.md)
