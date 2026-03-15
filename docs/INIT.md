# Helm Charts Repository Layout Guide

A public Helm charts monorepo for charts that fix or improve upon upstream
offerings, with automated testing, CI/CD, and Renovate-driven version tracking.

## Repository Structure

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
├── ct.yaml                         # chart-testing config
├── cr.yaml                         # chart-releaser config (optional)
├── .helmignore
├── LICENSE
└── README.md
```

## Key Design Decisions

### Chart Releaser for GitHub Pages Hosting

The `helm/chart-releaser-action` is the standard for public repos. It packages
charts, creates GitHub releases per chart version, and maintains a `gh-pages`
branch as the Helm repo index. Users add the repo with:

```sh
helm repo add yourname https://yourorg.github.io/helm-charts
```

### Chart Testing for Validation

`helm/chart-testing-action` handles the heavy lifting — it detects which charts
changed on a PR, lints them, and optionally installs them into a Kind cluster.
The `ci/` directory per chart holds test values files so you can test multiple
value combinations.

### Renovate for appVersion Tracking

Configure Renovate to watch `Chart.yaml` for the `appVersion` field and match it
against the upstream container registry or GitHub releases.

**`renovate.json5`:**

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
      // Track appVersion in Chart.yaml against container tags
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

Each `Chart.yaml` annotates the appVersion for Renovate to track:

```yaml
apiVersion: v2
name: some-app
version: 0.1.0
appVersion: "1.2.3" # renovate: datasource=docker depName=ghcr.io/org/some-app
```

Renovate picks up the annotation, watches the upstream source, and opens PRs to
bump `appVersion`. Bump `version` (the chart version) either manually or with a
small CI step that auto-increments patch on `appVersion` changes.

## CI Workflows

### `lint-test.yaml` (on PR)

1. `helm/chart-testing-action` with `ct lint-and-install`
2. Spins up a Kind cluster, installs changed charts with each `ci/*.yaml` values
   file
3. `helm-docs` diff check — fail if README is stale

### `release.yaml` (on push to main)

1. `helm/chart-releaser-action` — detects version bumps, packages, publishes to
   `gh-pages`

### helm-docs

Generate `README.md` per chart from a `README.md.gotmpl` template and the values
file comments. Enforce this in CI so docs never drift.

## Patterns Worth Adopting

### Multiple Test Values per Chart

One `ci/` directory per chart with multiple test values files
(`ci/default-values.yaml`, `ci/full-values.yaml`) so `ct install` runs multiple
scenarios. This is the chart-testing convention.

### Common Helper Patterns

Standardize your labels, selectors, and naming across all charts via
`_helpers.tpl` so they're consistent. Worth pulling a shared snippet into a doc
or even a library chart if you accumulate enough charts.

### Commit Chart.lock

Pin dependency versions by committing `Chart.lock`. Renovate can manage these
too if you have sub-chart dependencies.

### Conventional Commits Scoped per Chart

```
chart(technitium): bump appVersion to 1.2.3
```

Makes the release history clean and lets you automate changelogs per chart if
needed.

## Adding a New Chart

1. Drop a new directory under `charts/`
2. Annotate `appVersion` in `Chart.yaml` for Renovate
3. Add `ci/` test values for chart-testing
4. Add a `README.md.gotmpl` for helm-docs generation
5. Renovate + CT + CR handle the rest
