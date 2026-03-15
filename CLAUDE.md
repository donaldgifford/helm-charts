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

Renovate (`renovate.json5`) tracks `appVersion` in `Chart.yaml` via regex custom manager. Each chart annotates its appVersion:
```yaml
appVersion: "1.2.3" # renovate: datasource=docker depName=ghcr.io/org/app
```

## Chart Testing Config

`ct.yaml` configures chart-testing: charts dir is `charts/`, target branch is `main`. Charts have a separate yamllint config at `charts/.yamllint.yml` (150 char line limit, `templates/` dirs ignored).

## Conventions

- YAML indentation: 2 spaces, `document-start: present` required (see `.yamllint.yml`)
- Helm chart unit tests use the `helm-unittest` plugin
- Conventional commits scoped per chart: `chart(fleetdm): bump appVersion to 1.2.3`
- Documentation managed with `docz` CLI (`.docz.yaml`); doc types: RFC, ADR, Design, Impl, Plan, Investigation
- No library charts — duplicate shared helpers across charts
- Forge-managed files (listed in `.forge-lock.yaml`) should not be edited directly
