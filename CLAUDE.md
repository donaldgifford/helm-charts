# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Helm chart repository for Kubernetes applications. Charts live under `charts/` and are released to GitHub Pages via `helm/chart-releaser-action`. The repo was scaffolded from a `forge` blueprint (`go-ext`); config files managed by forge should not be manually edited (see `.forge-lock.yaml` for the list).

## Tool Versions

All tools are managed via **mise** (`mise.toml`). Key versions: Helm 3.19.0, Go 1.25.7, golangci-lint 2.8.0. Run `mise install` to set up the environment.

## Common Commands

### Helm Development
```
make helm-lint              # Lint all charts
make helm-unittest          # Run helm-unittest plugin tests
make helm-test              # Lint + unit tests combined
make helm-template          # Render templates with default values
make helm-template-ci       # Render templates with CI values
make helm-docs              # Generate chart README with helm-docs
make helm-ct-lint           # chart-testing lint (uses ct.yaml config)
make helm-ct-install        # Install and test in kind cluster
make helm-package           # Package chart to .tgz
```

### Go (for any Go tooling in the repo)
```
make test                   # Run all tests with race detector
make test-pkg PKG=./pkg/foo # Test a single package
make lint                   # golangci-lint
make lint-fix               # golangci-lint with auto-fix
make fmt                    # gofmt + goimports
make check                  # Quick pre-commit (lint + test)
make ci                     # Full CI pipeline (lint + test + build + license-check)
```

## CI Pipeline

GitHub Actions CI (`.github/workflows/ci.yml`) runs on PRs to `main`:
- **Lint** - `helm lint` on charts
- **Security** - Trivy filesystem vulnerability scan (HIGH/CRITICAL)
- **Helm Unit Tests** - `helm-unittest` plugin
- **Helm Chart Test** - `ct lint` and `ct install` (only when charts change)

Chart releases are triggered manually via `workflow_dispatch` on the `chart-release.yml` workflow.

## Chart Testing Config

`ct.yaml` configures chart-testing: charts dir is `charts/`, target branch is `main`. Charts have a separate yamllint config at `charts/.yamllint.yml` (150 char line limit, `templates/` dirs ignored).

## Conventions

- YAML indentation: 2 spaces, `document-start: present` required (see `.yamllint.yml`)
- Helm chart unit tests use the `helm-unittest` plugin
- Documentation managed with `docz` CLI (`.docz.yaml`); doc types: RFC, ADR, Design, Impl, Plan, Investigation
- Forge-managed files (listed in `.forge-lock.yaml`) should not be edited directly
