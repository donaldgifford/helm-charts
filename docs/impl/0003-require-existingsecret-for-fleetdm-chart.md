---
id: IMPL-0003
title: "Require cache.existingSecret in fleetdm chart"
status: InProgress
author: Donald Gifford
created: 2026-04-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0003: Require cache.existingSecret in fleetdm chart

**Status:** InProgress
**Author:** Donald Gifford
**Date:** 2026-04-28

<!--toc:start-->
- [Decisions](#decisions)
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 0: Pre-implementation capture](#phase-0-pre-implementation-capture)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 1: Chart change](#phase-1-chart-change)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 2: Live cluster migration](#phase-2-live-cluster-migration)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Scope: fix MySQL too, or just Redis? | Just Redis. The MySQL code path has the same vulnerability but our homelab already sets `database.existingSecret`, so it works in practice. [Issue #17](https://github.com/donaldgifford/helm-charts/issues/17) tracks the broader idiomatic Helm pattern (`secret.create` / `secret.name`) for both. |
| 2 | Reuse the existing Redis Secret name? | Yes — keep `<release>-redis` so the running Valkey StatefulSet doesn't need to restart. |
| 3 | Helper failure scope | Fail in `fleetdm.redisSecretName` whenever `cache.usePassword` is true (regardless of `valkey.enabled`) and `cache.existingSecret` is empty. The deployment env vars reference the helper output in all paths. |
| 4 | Chart version bump | Patch bump (0.4.3 → 0.4.4). This is a cache-side bug fix, not a broader interface change. |

## Objective

Stop the fleetdm chart from regenerating the Valkey/Redis password on every
re-render under `helm template` (ArgoCD without `--enable-helm-lookup`,
kustomize `helmCharts`, helmfile diff). Require `cache.existingSecret` to be
set whenever cache password auth is on. Leave the MySQL code path alone for
now — it has the same theoretical issue but is mitigated in our homelab by
already supplying `database.existingSecret`.

**Implements:** [INV-0001](../investigation/0001-fleetdm-secret-regeneration-under-helm-template.md)
(triggered by [issue #16](https://github.com/donaldgifford/helm-charts/issues/16))

## Scope

### In Scope

- Removing the Redis/Valkey Secret block from `charts/fleetdm/templates/secret.yaml`
- Adding a fail-closed guard in `fleetdm.redisSecretName` (in `_helpers.tpl`)
- Updating the unit tests, NOTES.txt, `cache.existingSecret` values comment,
  `README.md.gotmpl`, and CI values that touch the cache password path
- Bumping the chart from 0.4.3 to 0.4.4 and re-running `make helm-docs`
- One-time live migration of the homelab cluster's Valkey password from
  chart-managed (random) to externally-managed Secret, without restarting
  the Valkey StatefulSet

### Out of Scope

- The MySQL code path — same vulnerability exists in the chart but is
  mitigated by configuration. [Issue #17](https://github.com/donaldgifford/helm-charts/issues/17)
  tracks the broader fix for both via the idiomatic Helm
  `secret.create / secret.name` pattern.
- Adding `cache.password` (literal-value) support — that's part of the
  follow-up issue, not this PR.
- Renaming `cache.passwordKey` (default `redis-password`) — keep as-is.

## Implementation Phases

### Phase 0: Pre-implementation capture

Capture the homelab's current generated Valkey password before any code
changes, so the migration in phase 2 can recreate the Secret with the same
value (no Valkey pod restart).

#### Tasks

- [ ] Read the current `redis-password` from the live `fleetdm-redis` Secret
      and store somewhere durable (1Password, vault). Command:
      `kubectl get secret fleetdm-redis -n fleetdm -o jsonpath='{.data.redis-password}' | base64 -d`
- [ ] Sanity-check it matches what the running `fleetdm-valkey-0` pod has
      baked into its `VALKEY_PASSWORD` env. If they don't match, the
      Valkey StatefulSet has already drifted and a restart is unavoidable.
      Command:
      `kubectl exec -n fleetdm fleetdm-valkey-0 -- printenv VALKEY_PASSWORD`

#### Success Criteria

- The captured password is stored durably.
- We've confirmed whether the live Secret matches the running Valkey pod
  (and therefore whether the migration in phase 2 will be restart-free).

---

### Phase 1: Chart change

Single-file template change plus the supporting test/doc/values updates.

#### Tasks

- [x] In `charts/fleetdm/templates/secret.yaml`, remove the entire Redis
      Secret block (the `{{- if and .Values.cache.usePassword (not .Values.cache.existingSecret) }}`
      branch). Leave the MySQL block alone.
- [x] In `charts/fleetdm/templates/_helpers.tpl`, extend
      `fleetdm.redisSecretName`. Current logic:
      ```
      if .Values.cache.existingSecret → return it
      else → return "<fullname>-redis"
      ```
      New logic:
      ```
      if .Values.cache.existingSecret → return it
      else if .Values.cache.usePassword → fail with actionable message
      else → return "<fullname>-redis" (won't be referenced anyway)
      ```
      Failure message:
      `"cache.existingSecret is required when cache.usePassword is true. The chart no longer generates passwords (see INV-0001). Provision the Secret out-of-band."`
- [x] Update `charts/fleetdm/tests/secret_test.yaml`:
  - Drop the `renders Redis secret when cache.usePassword and no existingSecret` test.
  - Drop the `skips Redis secret when cache.existingSecret is set` test (no
    longer relevant — the chart never renders a Redis Secret).
  - Drop the `all secrets have resource-policy keep annotation` Redis half
    of the assertion (only MySQL left).
  - Update the `renders both secrets with default values` test — there is
    only one secret now (MySQL), so rename and adjust count.
- [x] Update `charts/fleetdm/tests/valkey_test.yaml`:
  - Find any test that lets the chart fall back to the chart-generated
    Redis Secret name (`<release>-redis`) without setting `cache.existingSecret`.
    Update it to set `cache.existingSecret: my-redis-secret` and assert
    the env-var reference points there.
- [x] Update `charts/fleetdm/tests/deployment_test.yaml`:
  - Same treatment for any deployment-level test that relies on the
    chart-generated Redis Secret name.
- [x] Update `charts/fleetdm/values.yaml` — change the helm-docs comment on
      `cache.existingSecret`:
      `Required when cache.usePassword is true. Provision the Secret out-of-band (External Secrets, 1Password Operator, raw kubectl apply, etc.). Must contain a key matching cache.passwordKey.`
- [x] Update `charts/fleetdm/templates/NOTES.txt` — if there's any line
      referring to the chart auto-generating the cache password, remove or
      adjust it. Add a one-line reminder if appropriate.
- [x] Update `charts/fleetdm/README.md.gotmpl` — in the "Secret Management"
      section, note that `cache.existingSecret` is required for cache
      password auth (mirror the wording for the eventual `database` fix in
      the follow-up issue).
- [x] Update `charts/fleetdm/ci/default-values.yaml` — confirm
      `cache.usePassword: false` so the existing CI values still render
      cleanly without needing a stub Secret. (If `usePassword: true`, add
      `cache.existingSecret: fleet-redis-stub`.)
- [x] Update `charts/fleetdm/ci/ha-values.yaml` — same check; add
      `cache.existingSecret: fleet-redis-stub` if `usePassword` is true.
- [x] Bump `charts/fleetdm/Chart.yaml` `version` from `0.4.3` to `0.4.4`.
- [x] Run `make helm-docs`.
- [x] Run `make helm-test` and confirm all suites pass.
- [x] Run `make helm-ct-lint` and confirm both CI values files pass.
- [x] Run `helm template charts/fleetdm` (default values, then with
      `cache.usePassword=true cache.existingSecret=""`) and confirm the
      latter fails with the expected message.
- [x] Open the PR. Reference INV-0001 and close issue #16 in the body.
      ([PR #18](https://github.com/donaldgifford/helm-charts/pull/18))
- [x] Confirm all CI jobs go green. (All 7 CI jobs passed on PR #18:
      Validate Renovate Config, Chart Version Check, Helm Unit Tests,
      Chart Testing, Helm Lint, Helm Docs Check, Security Scan.)
- [ ] Merge. (Operator action — held for user review.)

#### Success Criteria

- `templates/secret.yaml` has no Redis block; only the MySQL one remains.
- `helm template` with `cache.usePassword: true` and no `existingSecret`
  fails with the actionable error.
- `helm template` with `cache.usePassword: true` and a stub `existingSecret`
  renders successfully and the deployment env points at the stub Secret.
- `make helm-test` and `make helm-ct-lint` pass locally and in CI.
- `Chart Version Check` CI job passes (chart files changed AND version
  bumped).
- All other CI jobs are green.

---

### Phase 2: Live cluster migration

After the PR merges, point the homelab's `cache.existingSecret` at a
real externally-managed Secret containing the captured password.

#### Tasks

- [ ] Apply a Kubernetes Secret named `fleetdm-redis` (or whatever name
      makes sense — same name as the chart used to create is the
      restart-free choice) containing the password captured in phase 0
      under the `redis-password` key. Path doesn't matter much (raw
      `kubectl apply`, sealed-secrets, External Secrets) — it just needs
      to exist before the upgrade.
- [ ] Strip the `helm.sh/resource-policy: keep` annotation from the
      currently-running chart-managed Secret if reusing the same name, so
      ArgoCD/the new manifest can take it over cleanly:
      `kubectl annotate secret fleetdm-redis -n fleetdm helm.sh/resource-policy-`
- [ ] Update the homelab values overlay:
      `cache.existingSecret: fleetdm-redis`.
- [ ] Apply via ArgoCD. Confirm Fleet's Deployment rolls cleanly and the
      Valkey StatefulSet does **not** restart.
- [ ] Verify Fleet logs show no `WRONGPASS` or `AUTH` errors after the
      rollout.
- [ ] Trigger a second ArgoCD sync and confirm the `fleetdm-redis` Secret
      data is byte-for-byte identical (regression test for INV-0001).
- [ ] Close issue #16 (auto-closes on PR merge if linked, but verify).

#### Success Criteria

- Valkey StatefulSet has not restarted as part of the migration.
- Fleet pods are passing readiness/liveness probes after rollout.
- A second ArgoCD re-render does not mutate the Secret data.
- Issue #16 is closed.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `charts/fleetdm/templates/secret.yaml` | Modify | Remove the Redis/Valkey Secret block. |
| `charts/fleetdm/templates/_helpers.tpl` | Modify | Add a `fail` in `fleetdm.redisSecretName` when `cache.usePassword` is true and `cache.existingSecret` is empty. |
| `charts/fleetdm/tests/secret_test.yaml` | Modify | Drop Redis-related tests; adjust counts. |
| `charts/fleetdm/tests/valkey_test.yaml` | Modify | Update tests that relied on the chart-generated Redis Secret name. |
| `charts/fleetdm/tests/deployment_test.yaml` | Modify | Same — update any test that referenced the auto-generated Redis Secret. |
| `charts/fleetdm/values.yaml` | Modify | Update `cache.existingSecret` helm-docs comment to mark it required. |
| `charts/fleetdm/templates/NOTES.txt` | Modify (maybe) | Remove auto-generation language for cache; mention `cache.existingSecret` requirement. |
| `charts/fleetdm/README.md.gotmpl` | Modify | Note `cache.existingSecret` is required for cache auth. |
| `charts/fleetdm/README.md` | Regenerate | Output of `make helm-docs`. |
| `charts/fleetdm/Chart.yaml` | Modify | Bump `version` to `0.4.4`. |
| `charts/fleetdm/ci/default-values.yaml` | Modify (maybe) | Add `cache.existingSecret: fleet-redis-stub` if `cache.usePassword` is true there. |
| `charts/fleetdm/ci/ha-values.yaml` | Modify (maybe) | Same. |

## Testing Plan

- **Unit tests (`helm-unittest`)** — phase 1 covers updates to
  `secret_test.yaml`, `valkey_test.yaml`, and `deployment_test.yaml`.
- **Lint (`ct lint`)** — both CI values files must continue to pass.
- **Render (`helm template`)** — phase 1 explicitly verifies the failure
  path (no `existingSecret`) and the success path (with `existingSecret`).
- **Live regression (homelab)** — phase 2 covers the actual two-sync test
  for INV-0001.

## Dependencies

- **None internal.**
- **External:** the homelab's `fleetdm-redis` Secret needs to exist (with
  the captured password value) before the chart upgrade ships, so the
  render doesn't fail.
- **`Chart Version Check` CI job** (in main from PR #5) blocks the PR if
  we forget to bump `Chart.yaml`.

## Open Questions

None for this minimal scope. All resolved in the [Decisions](#decisions)
table.

The broader question — should the chart support the idiomatic Helm
`secret.create / secret.name` pattern for both MySQL and Redis — is
tracked in [issue #17](https://github.com/donaldgifford/helm-charts/issues/17),
not in this implementation.

## References

- [INV-0001 — FleetDM Secret Regeneration Under helm template](../investigation/0001-fleetdm-secret-regeneration-under-helm-template.md)
- [Issue #16](https://github.com/donaldgifford/helm-charts/issues/16)
- [PR #15 — original `lookup` fix](https://github.com/donaldgifford/helm-charts/pull/15)
- [Issue #17 — adopt idiomatic Helm secret pattern for MySQL and Valkey](https://github.com/donaldgifford/helm-charts/issues/17) (follow-up to this impl)
