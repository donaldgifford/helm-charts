# fleetdm

A Helm chart for FleetDM — open-source device management with embedded MySQL and optional Valkey cache

![Version: 0.4.1](https://img.shields.io/badge/Version-0.4.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.82.0](https://img.shields.io/badge/AppVersion-4.82.0-informational?style=flat-square)

## Prerequisites

| Dependency | Required Version | Required |
|------------|-----------------|----------|
| Kubernetes | 1.25+ | Yes |
| Helm | 3.10+ | Yes |
| Gateway API CRDs | v1 | When `httpRoute.enabled: true` with `parentRefs` set |
| cert-manager | v1.12+ | When `httpRoute.certManager.enabled: true` |

## Installation

```sh
helm repo add donaldgifford https://donaldgifford.github.io/helm-charts
helm repo update

# Default install with embedded MySQL and Valkey disabled
helm install fleet donaldgifford/fleetdm \
  --set cache.address=redis:6379

# Install with embedded MySQL and embedded Valkey
helm install fleet donaldgifford/fleetdm \
  --set valkey.enabled=true

# Install with external MySQL (embedded MySQL disabled)
helm install fleet donaldgifford/fleetdm \
  --set mysql.enabled=false \
  --set database.address=mysql:3306 \
  --set database.existingSecret=my-mysql-secret \
  --set cache.address=redis:6379
```

## Database

The chart includes an embedded MySQL 8.0 StatefulSet that is enabled by default.
MySQL automatically creates the Fleet database and user on first startup via
`MYSQL_DATABASE`, `MYSQL_USER`, and `MYSQL_PASSWORD` environment variables.

To use an external MySQL (RDS, Aurora, Cloud SQL, etc.), disable the embedded
MySQL and provide the connection details:

```yaml
mysql:
  enabled: false

database:
  address: "my-rds-instance.region.rds.amazonaws.com:3306"
  existingSecret: fleet-mysql-credentials
  passwordKey: mysql-password
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
| database.address | string | `""` | MySQL server address (auto-derived from embedded MySQL when empty and mysql.enabled is true) |
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
| livenessProbe.failureThreshold | int | `6` | Liveness probe failure threshold |
| livenessProbe.initialDelaySeconds | int | `120` | Liveness probe initial delay (increase on first deploy while schema imports) |
| livenessProbe.periodSeconds | int | `10` | Liveness probe period |
| livenessProbe.timeoutSeconds | int | `5` | Liveness probe timeout |
| mysql.enabled | bool | `true` | Deploy an embedded MySQL StatefulSet |
| mysql.image.repository | string | `"mysql"` | MySQL image repository |
| mysql.image.tag | string | `"8.0"` | MySQL image tag |
| mysql.persistence.enabled | bool | `true` | Enable persistent storage for MySQL |
| mysql.persistence.size | string | `"10Gi"` | MySQL PVC size |
| mysql.persistence.storageClassName | string | `""` | MySQL storage class name (uses cluster default when empty) |
| mysql.resources.limits.memory | string | `"1Gi"` | MySQL memory limit |
| mysql.resources.requests.cpu | string | `"250m"` | MySQL CPU request |
| mysql.resources.requests.memory | string | `"512Mi"` | MySQL memory request |
| mysql.service.port | int | `3306` | MySQL service port |
| nameOverride | string | `""` | Override the chart name |
| nodeSelector | object | `{}` | Node selector for Fleet pods |
| podDisruptionBudget.enabled | bool | `false` | Enable PodDisruptionBudget |
| podDisruptionBudget.minAvailable | int | `1` | Minimum number of available pods |
| readinessProbe.failureThreshold | int | `3` | Readiness probe failure threshold |
| readinessProbe.initialDelaySeconds | int | `120` | Readiness probe initial delay (increase on first deploy while schema imports) |
| readinessProbe.periodSeconds | int | `10` | Readiness probe period |
| readinessProbe.timeoutSeconds | int | `5` | Readiness probe timeout |
| replicaCount | int | `1` | Number of Fleet server replicas (ignored when autoscaling is enabled) |
| resources.limits.memory | string | `"512Mi"` | Fleet memory limit |
| resources.requests.cpu | string | `"250m"` | Fleet CPU request |
| resources.requests.memory | string | `"256Mi"` | Fleet memory request |
| revisionHistoryLimit | int | `1` | Number of old ReplicaSets to retain for rollback |
| service.port | int | `8080` | Service port |
| service.type | string | `"ClusterIP"` | Service type |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations |
| serviceAccount.create | bool | `true` | Create a ServiceAccount |
| serviceAccount.name | string | `""` | Override the ServiceAccount name (defaults to fullname) |
| startupProbe.enabled | bool | `true` | Enable startup probe (recommended for first deploy to allow schema migration time) |
| startupProbe.failureThreshold | int | `30` | Startup probe failure threshold (periodSeconds * failureThreshold = max startup time) |
| startupProbe.periodSeconds | int | `10` | Startup probe period |
| startupProbe.timeoutSeconds | int | `5` | Startup probe timeout |
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
