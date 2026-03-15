# helm-charts

Helm charts for Kubernetes applications. Charts fix or improve upon upstream offerings
with automated testing, CI/CD, and Renovate-driven version tracking.

## Usage

```sh
helm repo add donaldgifford https://donaldgifford.github.io/helm-charts
helm repo update
helm search repo donaldgifford
```

## Charts

| Chart | Description |
|-------|-------------|
| [fleetdm](charts/fleetdm/) | FleetDM — open-source device management with PXC-backed MySQL and optional Valkey cache |

## Development

All tools are managed via [mise](https://mise.jdx.dev/). Run `mise install` to set up
the environment.

```sh
make helm-lint          # Lint all charts
make helm-unittest      # Run unit tests
make helm-test          # Lint + unit tests
make helm-docs          # Generate chart READMEs
make ci                 # Full CI pipeline
```

See individual chart READMEs for chart-specific documentation and values.

## Contributing

1. Create a new chart under `charts/<name>/`
2. Add `ci/` test values for chart-testing
3. Add a `README.md.gotmpl` for helm-docs generation
4. Annotate `appVersion` in `Chart.yaml` for Renovate tracking
5. Open a PR — CI handles lint, test, and install validation
