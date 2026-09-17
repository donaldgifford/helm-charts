# chartdb

A Helm chart for ChartDB — open-source database diagram editor

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.20.1](https://img.shields.io/badge/AppVersion-1.20.1-informational?style=flat-square)

## Prerequisites

| Dependency | Required Version | Required |
|------------|-----------------|----------|
| Kubernetes | 1.25+ | Yes |
| Helm | 3.10+ | Yes |
| Gateway API CRDs | v1 | When `chartdb.httpRoute.enabled: true` with `parentRefs` set |
| cert-manager | v1.12+ | When `chartdb.httpRoute.certManager.enabled: true` |

ChartDB is a stateless, single-page React app served by nginx. It has
**no backing services** — no database, cache, ClickHouse, or object
storage. Connections to user databases happen entirely in the browser.

## Installation

```sh
helm repo add donaldgifford https://donaldgifford.github.io/helm-charts
helm repo update

# Default install (ClusterIP only, no north-south)
helm install chartdb donaldgifford/chartdb

# Install with classic Ingress
helm install chartdb donaldgifford/chartdb \
  --set chartdb.ingress.enabled=true \
  --set chartdb.ingress.hosts[0].host=chartdb.example.com \
  --set chartdb.ingress.hosts[0].paths[0].path=/ \
  --set chartdb.ingress.hosts[0].paths[0].pathType=Prefix

# Install with Gateway API HTTPRoute
helm install chartdb donaldgifford/chartdb \
  --set chartdb.httpRoute.enabled=true \
  --set chartdb.httpRoute.hostname=chartdb.example.com \
  --set chartdb.httpRoute.parentRefs[0].name=my-gateway \
  --set chartdb.httpRoute.parentRefs[0].namespace=gateway-system

# Install with OpenAI integration (requires existingSecret)
kubectl create secret generic chartdb-openai \
  --from-literal=openai-api-key='sk-...' \
  -n <namespace>

helm install chartdb donaldgifford/chartdb \
  --set chartdb.openai.enabled=true \
  --set chartdb.openai.existingSecret=chartdb-openai
```

## Configuration

All app-shaped values live under `chartdb.*`. Only `nameOverride` and
`fullnameOverride` live at the top level. See [DESIGN-0003][design-0003]
for the rationale behind the values layout, security context choices,
and the `seed-nginx-template` init container that supports
`readOnlyRootFilesystem: true`.

## Secret Management

The chart **never** manages the OpenAI Secret. When
`chartdb.openai.enabled: true`, you must provision the Secret
out-of-band and set `chartdb.openai.existingSecret`. The helper
`chartdb.openaiSecretName` fails closed with an actionable error if
the chart is rendered with OpenAI enabled but no Secret name set.

This pattern avoids password regeneration under `helm template`-driven
workflows like ArgoCD without `--enable-helm-lookup`, kustomize
`helmCharts`, or helmfile diff (see [INV-0001][inv-0001]).

Provision externally with External Secrets Operator, 1Password
Operator, sealed-secrets, or raw `kubectl create secret`:

```sh
kubectl create secret generic chartdb-openai \
  --from-literal=openai-api-key='sk-...' \
  -n <namespace>
```

[inv-0001]: https://github.com/donaldgifford/helm-charts/blob/main/docs/investigation/0001-fleetdm-secret-regeneration-under-helm-template.md
[design-0003]: https://github.com/donaldgifford/helm-charts/blob/main/docs/design/0003-chartdb-helm-chart.md

## Post-Install Validation

```sh
helm test chartdb -n <namespace>
```

This runs a curl probe against the Service to confirm the SPA is
serving.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| chartdb.additionalEnv | list | `[]` | List of additional environment variables to add to the chartdb container |
| chartdb.additionalEnvFrom | list | `[]` | List of additional envFrom entries to add to the chartdb container |
| chartdb.affinity | object | `{}` | Affinity rules for chartdb pods |
| chartdb.extraContainers | list | `[]` | Additional sidecar containers to add to the chartdb pod |
| chartdb.extraInitContainers | list | `[]` | Additional init containers to add to the chartdb pod |
| chartdb.extraLifecycle | object | `{}` | Lifecycle hooks for the chartdb container |
| chartdb.extraVolumeMounts | list | `[]` | Additional volume mounts to add to the chartdb container |
| chartdb.extraVolumes | list | `[]` | Additional volumes to add to the chartdb pod |
| chartdb.httpRoute.annotations | object | `{}` | HTTPRoute annotations |
| chartdb.httpRoute.certManager.certificateName | string | `""` | Certificate resource name (defaults to fullname-tls) |
| chartdb.httpRoute.certManager.clusterIssuer | string | `""` | cert-manager ClusterIssuer name |
| chartdb.httpRoute.certManager.enabled | bool | `false` | Enable cert-manager Certificate for HTTPRoute TLS |
| chartdb.httpRoute.enabled | bool | `false` | Enable Gateway API HTTPRoute (alternative to classic Ingress) |
| chartdb.httpRoute.hostname | string | `""` | Hostname for the HTTPRoute |
| chartdb.httpRoute.parentRefs | list | `[]` | Gateway parentRefs (HTTPRoute is only rendered when this list is non-empty) |
| chartdb.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| chartdb.image.pullSecrets | list | `[]` | Image pull secrets for private registries |
| chartdb.image.repository | string | `"ghcr.io/chartdb/chartdb"` | ChartDB container image repository |
| chartdb.image.tag | string | `""` | Image tag (defaults to chart appVersion when empty) |
| chartdb.ingress.annotations | object | `{}` | Ingress annotations |
| chartdb.ingress.className | string | `""` | Ingress class name |
| chartdb.ingress.enabled | bool | `true` | Enable classic Ingress |
| chartdb.ingress.hosts | list | `[]` | Ingress host rules |
| chartdb.ingress.tls | list | `[]` | Ingress TLS configuration |
| chartdb.livenessProbe.failureThreshold | int | `3` | Liveness probe failure threshold |
| chartdb.livenessProbe.initialDelaySeconds | int | `5` | Liveness probe initial delay |
| chartdb.livenessProbe.periodSeconds | int | `10` | Liveness probe period |
| chartdb.livenessProbe.timeoutSeconds | int | `3` | Liveness probe timeout |
| chartdb.nodeSelector | object | `{}` | Node selector for chartdb pods |
| chartdb.openai.apiKeyKey | string | `"openai-api-key"` | Key in the openai secret that holds the API key |
| chartdb.openai.enabled | bool | `false` | Enable wiring OPENAI_API_KEY env var from an existing Secret (required for ChartDB's AI features) |
| chartdb.openai.endpoint | string | `""` | Custom LLM endpoint URL (literal value, optional — e.g. for Azure OpenAI or local LLMs) |
| chartdb.openai.existingSecret | string | `""` | Name of an existing Secret containing the OpenAI API key (required when openai.enabled is true; chart never generates one — see INV-0001) |
| chartdb.openai.model | string | `""` | Custom LLM model name (literal value, optional) |
| chartdb.podAnnotations | object | `{}` | Annotations applied to the chartdb pod |
| chartdb.podLabels | object | `{}` | Additional labels applied to the chartdb pod |
| chartdb.podSecurityContext.fsGroup | int | `101` | Group id applied to mounted volumes |
| chartdb.podSecurityContext.runAsGroup | int | `101` | nginx group gid in the upstream alpine image |
| chartdb.podSecurityContext.runAsNonRoot | bool | `true` | Require non-root for all containers in the pod |
| chartdb.podSecurityContext.runAsUser | int | `101` | nginx user uid in the upstream alpine image |
| chartdb.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` | Seccomp profile type |
| chartdb.readinessProbe.failureThreshold | int | `3` | Readiness probe failure threshold |
| chartdb.readinessProbe.initialDelaySeconds | int | `2` | Readiness probe initial delay |
| chartdb.readinessProbe.periodSeconds | int | `5` | Readiness probe period |
| chartdb.readinessProbe.timeoutSeconds | int | `3` | Readiness probe timeout |
| chartdb.replicaCount | int | `1` | Number of ChartDB replicas |
| chartdb.resources.limits.memory | string | `"128Mi"` | chartdb memory limit (no CPU limit by default — nginx is bursty) |
| chartdb.resources.requests.cpu | string | `"10m"` | chartdb CPU request |
| chartdb.resources.requests.memory | string | `"32Mi"` | chartdb memory request |
| chartdb.revisionHistoryLimit | int | `1` | Number of old ReplicaSets to retain for rollback |
| chartdb.securityContext.allowPrivilegeEscalation | bool | `false` | Disallow privilege escalation |
| chartdb.securityContext.capabilities.add | list | `["NET_BIND_SERVICE"]` | Add NET_BIND_SERVICE so non-root nginx can bind to :80 |
| chartdb.securityContext.capabilities.drop | list | `["ALL"]` | Drop all Linux capabilities |
| chartdb.securityContext.readOnlyRootFilesystem | bool | `true` | Mount the container root filesystem read-only. Writable paths come from emptyDirs (see deployment template). |
| chartdb.service.port | int | `80` | Service port (clients connect here) |
| chartdb.service.type | string | `"ClusterIP"` | Service type (ClusterIP, NodePort, LoadBalancer) |
| chartdb.serviceAccount.annotations | object | `{}` | ServiceAccount annotations |
| chartdb.serviceAccount.automountServiceAccountToken | bool | `false` | Whether to automount the ServiceAccount token in the pod. ChartDB does not need API server access. |
| chartdb.serviceAccount.create | bool | `true` | Create a ServiceAccount |
| chartdb.serviceAccount.name | string | `""` | Override the ServiceAccount name (defaults to fullname) |
| chartdb.tolerations | list | `[]` | Tolerations for chartdb pods |
| chartdb.topologySpreadConstraints | list | `[]` | Topology spread constraints for chartdb pods |
| chartdb.ui.disableAnalytics | bool | `false` | Disable the Fathom analytics integration |
| chartdb.ui.hideChartdbCloud | bool | `false` | Hide the ChartDB cloud signup/login UI |
| fullnameOverride | string | `""` | Override the full release name |
| nameOverride | string | `""` | Override the chart name |

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Donald Gifford |  | <https://github.com/donaldgifford> |
