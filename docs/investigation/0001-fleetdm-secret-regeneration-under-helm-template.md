---
id: INV-0001
title: "FleetDM Secret Regeneration Under helm template"
status: Open
author: Donald Gifford
created: 2026-04-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# INV 0001: FleetDM Secret Regeneration Under helm template

**Status:** Open
**Author:** Donald Gifford
**Date:** 2026-04-28

<!--toc:start-->
- [Question](#question)
- [Hypothesis](#hypothesis)
- [Context](#context)
- [Approach](#approach)
- [Environment](#environment)
- [Findings](#findings)
- [Conclusion](#conclusion)
- [Recommendation](#recommendation)
- [Resolution Tasks](#resolution-tasks)
- [References](#references)
<!--toc:end-->

## Question

How should the fleetdm chart provision MySQL and Valkey/Redis credentials so
they remain stable across re-renders by `helm template`-based tooling
(ArgoCD without `--enable-helm-lookup`, kustomize `helmCharts`, helmfile diff)
without forcing every user to wire up an external secret manager on day one?

## Hypothesis

The current `lookup` + `randAlphaNum 32` fallback is fundamentally incompatible
with `helm template`-driven workflows. Any fix that preserves a "chart
generates a random password by default" experience under `helm template` will
require either a non-template generator (a hook Job that creates the Secret
out-of-band, then exits) or shifting responsibility to the user via
`existingSecret`. There is no pure-template trick that survives the
no-cluster-context render path.

## Context

`charts/fleetdm/templates/secret.yaml` was updated in PR #15
(commit `1313b7f`) to use:

```go-template
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
  {{ .Values.database.passwordKey }}: {{ index $existingSecret.data ... }}
{{- else }}
  {{ .Values.database.passwordKey }}: {{ randAlphaNum 32 | b64enc | quote }}
{{- end }}
```

The intent was to preserve generated passwords across `helm upgrade`. It works
for `helm install` / `helm upgrade` (which connect to a cluster) but fails
silently under `helm template` — `lookup` returns empty without a kubeconfig
context, so the `else` branch always runs and generates a fresh random value.

Real-world impact observed in the user's homelab (ArgoCD + kustomize
`helmCharts`):

```text
fleetdm-valkey-0   age 23d   VALKEY_PASSWORD=43jwc...   requirepass=43jwc...
fleetdm-redis Secret (after recent ArgoCD re-render): 0pJv...
fleetdm Deployment reads 0pJv... → AUTH fails (WRONGPASS)
```

The Valkey StatefulSet pod started 23 days ago with the original password
baked into its environment via `--requirepass $(VALKEY_PASSWORD)`. The Secret
in the cluster has since been rotated by repeated re-renders. Restarting the
StatefulSet temporarily fixes auth — until the next sync.

The MySQL secret has the same shape and the same vulnerability.

**Triggered by:** [issue #16](https://github.com/donaldgifford/helm-charts/issues/16)

## Approach

1. Reproduce the regeneration locally:
   - `helm template fleet charts/fleetdm | grep -A1 redis-password` twice and
     diff the output. Confirm passwords differ.
   - Repeat with `--dry-run=server` (which does have cluster context) to
     confirm `lookup` works in that path.
2. Survey the three candidate fixes from the issue and weigh against:
   - Out-of-the-box experience for `helm install` users (no external tooling).
   - Compatibility with ArgoCD (default config, no `--enable-helm-lookup`).
   - Compatibility with kustomize `helmCharts` and helmfile.
   - Migration cost for existing users who already have generated secrets in
     their clusters.
3. Survey upstream Helm charts that solve the same problem (Bitnami common,
   external-secrets, sealed-secrets community charts) for prior art.
4. Decide on the fix and break it into concrete implementation tasks.

## Environment

| Component | Version / Value |
|-----------|----------------|
| chart version | 0.4.3 |
| Helm | 3.19.0 |
| ArgoCD | default install (`--enable-helm-lookup` off) |
| Kustomize | `helmCharts` generator |
| Affected templates | `templates/secret.yaml` (MySQL + Redis branches) |

## Findings

### `lookup` returns empty under `helm template`

Per the [official Helm docs][lookup-docs], `lookup` returns an empty value
when the rendering context has no Kubernetes connection. `helm template`
explicitly uses no connection — that's the whole point of the command. There
is no `--enable-lookup` flag for `helm template`.

### ArgoCD default config does not enable lookup

Quoting the [ArgoCD Helm docs][argo-helm-docs]: `helm template` is invoked
without cluster credentials by default. The `--enable-helm-lookup` flag must
be explicitly enabled on the argocd-repo-server, and even then it's
discouraged because it bypasses ArgoCD's manifest-caching layer and forces
the repo-server to talk to the destination cluster on every refresh.

### Kustomize `helmCharts` and helmfile have no lookup support

Both tools shell out to `helm template` and have no analog for the
`--enable-lookup` flag. There is no path forward here — `lookup` will never
return populated data in those workflows.

### The "generate by default" UX is mutually exclusive with these tools

Any solution that wants to keep the "no values needed, chart works on first
install" experience under raw `helm template` would have to embed the
randomness in something *other than the template* — a hook Job, a one-shot
generator pod, an init container that writes to a Secret. None of those are
visible to `helm template`'s manifest output, so they don't solve the problem
either: ArgoCD/kustomize users still see a freshly-randomized Secret on every
sync.

### Prior art

- **Bitnami common (`common.secrets.passwords.manage`)** — does the same
  `lookup` dance with the same pitfalls. Bitnami's charts document
  `existingSecret` as the production path and treat the generated branch as
  a dev convenience.
- **External Secrets / 1Password Operator / sealed-secrets** — all assume
  the user provisions the Secret out-of-band. None embed generation in the
  Helm chart itself.
- **The PostgreSQL operator (CNPG)** generates credentials inside the
  operator (not Helm), then writes them to a Secret the user references.
  This sidesteps the problem entirely by moving generation outside the Helm
  render path.

The pattern across mature charts is clear: production users bring their own
secret, period. The "chart generates a random password" branch exists for
local-dev / `helm install` convenience and is documented as fragile.

## Conclusion

**Answer:** The current implementation cannot be fixed within the template.
The path forward is to make `existingSecret` the supported production
interface, keep the generated branch as an explicit opt-in dev convenience,
and warn users loudly when they're on the fragile path.

There is no purely-template fix that works for ArgoCD/kustomize users.

## Recommendation

Adopt **option 1** from the issue (require `existingSecret`) in a single PR.
We're the only consumers of this chart today, so the deprecation runway from
option 3 is unnecessary overhead — we can do a one-time migration of our
own running cluster's secrets and remove the fragile branch in one shot.

We should **not** invest in a hook-Job-based generator (option 2). It doesn't
solve the ArgoCD/kustomize case, and it adds a stateful sidecar that's
difficult to reason about during upgrades.

## Resolution Tasks

Single PR targeting chart version 0.5.0 (minor — breaking change for any
user still relying on the generated branch, but we're the only user).

### Pre-PR: capture current passwords from the live cluster

Before merging, extract the generated values currently running in our homelab
so we can recreate them under externally-managed Secrets without restarting
MySQL or Valkey pods:

```sh
kubectl get secret fleetdm-mysql -n fleetdm -o jsonpath='{.data.mysql-password}' | base64 -d
kubectl get secret fleetdm-mysql -n fleetdm -o jsonpath='{.data.mysql-root-password}' | base64 -d
kubectl get secret fleetdm-redis -n fleetdm -o jsonpath='{.data.redis-password}' | base64 -d
```

Stash these in 1Password (or whatever the live secret store is) under entries
that match the `existingSecret` we'll point the chart at after the upgrade.

### PR: remove the random-generation branch

- [ ] **Remove the `lookup` + `randAlphaNum` branches** from
      `templates/secret.yaml`. The whole `secret.yaml` template can shrink
      to nothing (or the file can be deleted) since the chart no longer
      owns secret generation. Both the MySQL and Redis branches go.
- [ ] **Add fail-closed guards in `_helpers.tpl`** — extend
      `fleetdm.mysqlSecretName` to fail when `mysql.enabled: true` and
      `database.existingSecret` is empty, with message:
      `"database.existingSecret is required. The chart no longer generates random passwords (see INV-0001). Provision the secret out-of-band (External Secrets, 1Password Operator, sealed-secrets, etc.)."`
      Same shape for the Valkey path via `fleetdm.redisSecretName` when
      `valkey.enabled: true` and `cache.existingSecret` is empty.
- [ ] **Update unit tests:**
  - `tests/secret_test.yaml` — delete (or replace with a "this template
    renders nothing" smoke test if we keep the file as a placeholder).
  - `tests/deployment_test.yaml` — the existing `references generated
    MySQL secret by default` test must be updated to assert the failure
    path instead, plus a new test that confirms `existingSecret` is wired
    through correctly.
  - `tests/mysql_test.yaml` — same: update the
    `references generated secret for MYSQL_PASSWORD` and
    `references generated secret for MYSQL_ROOT_PASSWORD` tests to require
    `existingSecret`.
  - `tests/valkey_test.yaml` — confirm the cache password path uses
    `existingSecret`.
- [ ] **Update CI values:**
  - `ci/default-values.yaml` already sets
    `database.existingSecret: fleet-mysql-stub` — confirm and add
    `cache.existingSecret: fleet-redis-stub` if the cache is enabled in
    that file.
  - `ci/ha-values.yaml` — same; confirm both `existingSecret`s are set so
    `ct lint` continues to render.
- [ ] **Add a `pre-render` Job (optional)** — only if we want the chart to
      keep working with `helm install` users in the future without external
      tooling. Skip for now since it doesn't solve the ArgoCD case and we
      don't need it.
- [ ] **Update `templates/NOTES.txt`** — remove any references to
      chart-managed secrets, replace with a one-line note that the chart
      requires externally-managed Secrets.
- [ ] **Update `values.yaml`** — extend the helm-docs comments on
      `database.existingSecret` and `cache.existingSecret` to make clear
      these are required (not optional) when the corresponding embedded
      service is enabled.
- [ ] **Update `README.md.gotmpl`** — the "Secret Management" section
      should remove the "chart generates random credentials by default"
      paragraph and replace with required-secret examples (raw `kubectl
      create secret`, External Secrets, 1Password Operator).
- [ ] **Bump chart version to 0.5.0** in `Chart.yaml` and re-run
      `make helm-docs`.
- [ ] **Run the full toolchain locally** before pushing:
      `make helm-test`, `make helm-ct-lint`, `make helm-docs-check`.
- [ ] **Close issue #16** in the PR body.

### Post-PR: migrate our live cluster

After the PR merges, in our homelab:

1. Create the externally-managed Secrets with the password values captured
   in the pre-PR step (1Password Operator, External Secrets, or even raw
   `kubectl apply` from a sealed-secrets manifest). Match the keys to
   `database.passwordKey` and `cache.passwordKey`.
2. Update our values overlay to set `database.existingSecret` and
   `cache.existingSecret` to the new Secret names.
3. Apply via ArgoCD. MySQL and Valkey pods don't restart (they read env
   vars at start, not on the fly), so as long as the Secret values match
   what the running pods have baked in, Fleet's Deployment can roll
   cleanly.
4. Delete the now-orphaned `fleetdm-mysql` and `fleetdm-redis` secrets the
   chart used to manage (they have `helm.sh/resource-policy: keep`, so
   they won't be cleaned up automatically).

### Optional follow-up

- [ ] **Provide a sample External Secrets / 1Password Operator manifest** in
      `charts/fleetdm/examples/` so future users have a concrete starting
      point.

## References

- [Issue #16](https://github.com/donaldgifford/helm-charts/issues/16)
- [PR #15 — original `lookup` fix](https://github.com/donaldgifford/helm-charts/pull/15)
- [Helm docs — lookup function][lookup-docs]
- [ArgoCD docs — Helm lookup][argo-helm-docs]
- [External Secrets Operator](https://external-secrets.io/)
- [1Password Operator](https://github.com/1Password/onepassword-operator)

[lookup-docs]: https://helm.sh/docs/chart_template_guide/functions_and_pipelines/#using-the-lookup-function
[argo-helm-docs]: https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
