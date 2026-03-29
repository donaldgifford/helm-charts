# fleetdm

A Helm chart for FleetDM — open-source device management with PXC-backed MySQL and optional Valkey cache

![Version: 0.3.3](https://img.shields.io/badge/Version-0.3.3-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.82.0](https://img.shields.io/badge/AppVersion-4.82.0-informational?style=flat-square)

## Prerequisites

| Dependency | Required Version | Required |
|------------|-----------------|----------|
| Kubernetes | 1.25+ | Yes |
| Helm | 3.10+ | Yes |
| PXC Operator | 1.13+ | When `pxc.enabled: true` |
| Gateway API CRDs | v1 | When `httpRoute.enabled: true` with `parentRefs` set |
| cert-manager | v1.12+ | When `httpRoute.certManager.enabled: true` |

## Installation

```sh
helm repo add donaldgifford https://donaldgifford.github.io/helm-charts
helm repo update

# Minimal install with external MySQL and Redis
helm install fleet donaldgifford/fleetdm \
  --set pxc.enabled=false \
  --set database.address=mysql:3306 \
  --set database.existingSecret=my-mysql-secret \
  --set cache.address=redis:6379

# Install with PXC cluster and embedded Valkey
helm install fleet donaldgifford/fleetdm \
  --set valkey.enabled=true
```

## Secret Management

The chart generates random credentials by default. Generated secrets use
`helm.sh/resource-policy: keep` to survive Helm upgrades.

To use externally managed secrets (1Password Connect, External Secrets Operator):

```yaml
database:
  existingSecret: fleet-mysql-credentials
  passwordKey: mysql-password

cache:
  existingSecret: fleet-redis-credentials
  passwordKey: redis-password

pxc:
  existingSecret: fleet-pxc-credentials
```

## Post-Install Validation

```sh
helm test fleet -n <namespace>
```

This runs MySQL connectivity, cache connectivity, and Fleet `/healthz` checks.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules for Fleet pods |
| autoscaling.enabled | bool | `false` | Enable HorizontalPodAutoscaler |
| autoscaling.maxReplicas | int | `10` | Maximum number of replicas |
| autoscaling.minReplicas | int | `2` | Minimum number of replicas |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilization percentage |
| cache.address | string | `""` | Cache server address (auto-derived from Valkey when empty and valkey.enabled is true) |
| cache.database | string | `"0"` | Redis database number |
| cache.existingSecret | string | `""` | Name of an existing secret containing the cache password |
| cache.passwordKey | string | `"redis-password"` | Key in the cache secret that holds the password |
| cache.usePassword | bool | `true` | Enable password authentication for cache |
| database.address | string | `""` | MySQL server address (auto-derived from PXC when empty and pxc.enabled is true) |
| database.connMaxLifetime | string | `"0"` | Maximum lifetime of a database connection (Go duration string) |
| database.existingSecret | string | `""` | Name of an existing secret containing the MySQL password |
| database.maxIdleConns | int | `50` | Maximum number of idle database connections |
| database.maxOpenConns | int | `50` | Maximum number of open database connections |
| database.name | string | `"fleet"` | MySQL database name |
| database.passwordKey | string | `"mysql-password"` | Key in the MySQL secret that holds the password |
| database.username | string | `"fleet"` | MySQL username |
| fleet.appToken.keySize | int | `24` | App token key size in bytes |
| fleet.appToken.validityPeriod | string | `"8760h"` | App token validity period (Go duration string) |
| fleet.auth.bcryptCost | int | `12` | Bcrypt cost for password hashing |
| fleet.auth.saltKeySize | int | `24` | Salt key size in bytes |
| fleet.autoApplySQLMigrations | bool | `true` | Automatically apply SQL migrations on startup |
| fleet.license.secretKey | string | `"license-key"` | Key in the license secret that holds the license value |
| fleet.license.secretName | string | `""` | Name of an existing secret containing the Fleet Premium license key |
| fleet.logging.debug | bool | `false` | Enable debug logging |
| fleet.logging.disableBanner | bool | `false` | Disable the Fleet startup banner |
| fleet.logging.json | bool | `true` | Use JSON-formatted logs |
| fleet.serverURL | string | `""` | Fleet server URL (the external URL users/agents connect to) |
| fleet.session.duration | string | `"2160h"` | Session duration (Go duration string) |
| fleet.session.keySize | int | `64` | Session key size in bytes |
| fleet.tls.enabled | bool | `false` | Enable TLS termination in Fleet (usually false when TLS terminates at the gateway) |
| fleet.vulnerabilities.databasesPath | string | `"/tmp/vuln"` | Path for vulnerability database files |
| fullnameOverride | string | `""` | Override the full release name |
| httpRoute.certManager.certificateName | string | `""` | Certificate resource name (defaults to fullname-tls) |
| httpRoute.certManager.clusterIssuer | string | `""` | cert-manager ClusterIssuer name |
| httpRoute.certManager.enabled | bool | `false` | Enable cert-manager Certificate for HTTPRoute TLS |
| httpRoute.enabled | bool | `true` | Enable Gateway API HTTPRoute |
| httpRoute.hostname | string | `""` | Hostname for the HTTPRoute |
| httpRoute.parentRefs | list | `[]` | Gateway parentRefs (HTTPRoute is only rendered when this list is non-empty) |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| image.repository | string | `"fleetdm/fleet"` | Fleet container image repository |
| image.tag | string | `""` | Overrides the image tag (defaults to the chart appVersion) |
| imagePullSecrets | list | `[]` | Image pull secrets for private registries |
| ingress.annotations | object | `{}` | Ingress annotations |
| ingress.className | string | `""` | Ingress class name |
| ingress.enabled | bool | `false` | Enable classic Ingress (disabled by default; use httpRoute instead) |
| ingress.hosts | list | `[]` | Ingress host rules |
| ingress.tls | list | `[]` | Ingress TLS configuration |
| nameOverride | string | `""` | Override the chart name |
| nodeSelector | object | `{}` | Node selector for Fleet pods |
| podDisruptionBudget.enabled | bool | `false` | Enable PodDisruptionBudget |
| podDisruptionBudget.minAvailable | int | `1` | Minimum number of available pods |
| pxc.allowUnsafe | bool | `false` | Allow unsafe single-node PXC and single-replica HAProxy (dev/test only, NOT for production) |
| pxc.backup.enabled | bool | `false` | Enable PXC scheduled backups |
| pxc.backup.s3Bucket | string | `""` | S3 bucket name for backups |
| pxc.backup.s3CredentialsSecret | string | `""` | S3 credentials secret name |
| pxc.backup.s3Region | string | `"us-east-1"` | S3 region |
| pxc.backup.schedule | string | `"0 4 * * *"` | Backup schedule (cron expression) |
| pxc.backup.storageType | string | `"s3"` | Backup storage type (s3 or filesystem) |
| pxc.clusterName | string | `"fleet-pxc"` | PXC cluster name |
| pxc.enabled | bool | `true` | Deploy a PerconaXtraDBCluster CR for MySQL |
| pxc.existingSecret | string | `""` | Name of an existing secret for PXC credentials |
| pxc.haproxy.enabled | bool | `true` | Enable HAProxy for PXC |
| pxc.haproxy.image.repository | string | `"percona/haproxy"` | HAProxy image repository |
| pxc.haproxy.image.tag | string | `"2.8.5"` | HAProxy image tag |
| pxc.haproxy.resources.limits.memory | string | `"256Mi"` | HAProxy memory limit |
| pxc.haproxy.resources.requests.cpu | string | `"100m"` | HAProxy CPU request |
| pxc.haproxy.resources.requests.memory | string | `"128Mi"` | HAProxy memory request |
| pxc.haproxy.size | int | `2` | Number of HAProxy replicas |
| pxc.image.repository | string | `"percona/percona-xtradb-cluster"` | PXC image repository |
| pxc.image.tag | string | `"8.0.36-28.1"` | PXC image tag |
| pxc.initContainer.resources.limits.cpu | string | `"200m"` | PXC init container CPU limit |
| pxc.initContainer.resources.limits.memory | string | `"200M"` | PXC init container memory limit |
| pxc.initContainer.resources.requests.cpu | string | `"100m"` | PXC init container CPU request |
| pxc.initContainer.resources.requests.memory | string | `"100M"` | PXC init container memory request |
| pxc.initJob.image.repository | string | `"mysql"` | MySQL init job image repository |
| pxc.initJob.image.tag | string | `"8.0"` | MySQL init job image tag |
| pxc.resources.limits.memory | string | `"2Gi"` | PXC node memory limit |
| pxc.resources.requests.cpu | string | `"600m"` | PXC node CPU request |
| pxc.resources.requests.memory | string | `"1Gi"` | PXC node memory request |
| pxc.size | int | `3` | Number of PXC nodes (must be odd: 1, 3, 5, or 7) |
| pxc.storage.size | string | `"20Gi"` | PXC storage size per node |
| pxc.storage.storageClassName | string | `""` | PXC storage class name (uses cluster default when empty) |
| replicaCount | int | `1` | Number of Fleet server replicas (ignored when autoscaling is enabled) |
| resources.limits.memory | string | `"512Mi"` | Fleet memory limit |
| resources.requests.cpu | string | `"250m"` | Fleet CPU request |
| resources.requests.memory | string | `"256Mi"` | Fleet memory request |
| service.port | int | `8080` | Service port |
| service.type | string | `"ClusterIP"` | Service type |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations |
| serviceAccount.create | bool | `true` | Create a ServiceAccount |
| serviceAccount.name | string | `""` | Override the ServiceAccount name (defaults to fullname) |
| tolerations | list | `[]` | Tolerations for Fleet pods |
| valkey.enabled | bool | `false` | Deploy an embedded Valkey (Redis-compatible) instance |
| valkey.image.repository | string | `"valkey/valkey"` | Valkey image repository |
| valkey.image.tag | string | `"9.0.3"` | Valkey image tag |
| valkey.persistence.enabled | bool | `false` | Enable persistent storage for Valkey |
| valkey.persistence.size | string | `"1Gi"` | Valkey PVC size |
| valkey.persistence.storageClassName | string | `""` | Valkey storage class name (uses cluster default when empty) |
| valkey.replicaCount | int | `1` | Number of Valkey replicas |
| valkey.resources.limits.memory | string | `"256Mi"` | Valkey memory limit |
| valkey.resources.requests.cpu | string | `"100m"` | Valkey CPU request |
| valkey.resources.requests.memory | string | `"128Mi"` | Valkey memory request |
| valkey.service.port | int | `6379` | Valkey service port |

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Donald Gifford |  | <https://github.com/donaldgifford> |
