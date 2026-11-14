# Troubleshooting

## Quick triage

```bash
kubectl -n argocd get applications -o wide           # what isn't Synced/Healthy?
kubectl get pods -A | grep -Ev 'Running|Completed'   # broken pods
kubectl get nodeclaims,nodes -L workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get events -A --field-selector source=karpenter   # node auto-provisioning decisions
```

## Terraform

| Error | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` / `state blob is already locked` | concurrent run / crashed run (blob lease) | wait; else `terraform force-unlock <id>` |
| `AuthorizationPermissionMismatch` on the backend | no *Storage Blob Data Contributor* on the state account (shared keys are disabled) | grant it to yourself; CI identities get it from `terraform/global` |
| `Kubernetes cluster unreachable` / `dial tcp ... i/o timeout` | API server authorized IP ranges | add your IP to `api_server_authorized_ip_ranges` |
| `exec: "kubelogin": executable file not found` | kubelogin missing | `az aks install-cli` (CI: `azure/use-kubelogin`) |
| `Forbidden: User "<object id>" cannot ...` | no Azure RBAC for Kubernetes on the cluster, or still propagating | ensure your object id is in `cluster_admin_object_ids`; wait ≤ 5 min after first apply |
| `AADSTS700213: No matching federated identity record` (CI) | workflow subject ≠ federated credential | repo/branch/Environment names must match `terraform/global` (`github_org`, `github_repo`, `environments`) |
| `ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity` | parallel writes on one identity | transient; re-apply (credentials are created in tiers) |
| `VaultAlreadySoftDeleted` / name conflicts after destroy | Key Vault soft delete | `az keyvault purge -n <kv>` (dev only — prod has purge protection) |
| destroy hangs / `InUseSubnetCannotBeDeleted` | NICs of auto-provisioned VMs or the gateway still attached | run `scripts/teardown.sh`, which removes k8s-owned Azure resources first |

## Argo CD

| Symptom | Fix |
|---|---|
| App `Unknown` / `ComparisonError: ... CRD not found` | CRD from an earlier wave not installed yet → wait / sync parent; check that operator app is Healthy |
| `metadata.annotations: Too long` | add `ServerSideApply=true` to the app's `syncOptions` in `argocd/app-of-apps/values.yaml` |
| Child app renders `required` errors (`image.repository is required`, `...clientId is required`) | the root app lacks the `cloud:` facts — it must be created by Terraform (`modules/platform`), not by hand; `kubectl -n argocd get app root-<env> -o yaml \| yq .spec.source.helm.valuesObject` |
| JupyterHub app always OutOfSync on `Secret/hub` | expected without `ignoreDifferences` (already configured) |
| Manual change reverted | self-heal is on by design — change Git instead |
| Private repo: `authentication required` | `argocd repo add https://github.com/... --username x --password <PAT>` |

## Node auto-provisioning (Karpenter) / GPU

| Symptom | Fix |
|---|---|
| GPU pod Pending, no NodeClaim | pod lacks toleration `nvidia.com/gpu` or nodeSelector `workload: ml-gpu`; NodePool `limits` reached |
| NodeClaim not Ready, event `QuotaExceeded` / `OperationNotAllowed` | regional or family vCPU quota (Portal › Quotas) |
| NodeClaim `SkuNotAvailable` / `AllocationFailed` / `ZonalAllocationFailed` | widen `gpu.skus` / `cpu.skuFamilies`, allow more zones, or switch region |
| AKSNodeClass not Ready | `kubectl describe aksnodeclass gpu` — usually `vnetSubnetID` or the cluster identity lacking *Network Contributor* on the VNet |
| Node Ready but `nvidia.com/gpu: 0` | GPU operator device-plugin pod on that node: `kubectl -n gpu-operator get pods -o wide`; `nvidia-operator-validator` logs |
| Spot nodes churn in dev | expected (evictions); PDBs drain gracefully. Set `cpu.capacityTypes: [on-demand]` if disruptive |
| No Karpenter metrics / controller pod | by design: NAP runs in the managed control plane; use `karpenter_nodepool_*` / `karpenter_nodeclaim_*` (kube-state-metrics) and events |

## Data plane

| Symptom | Fix |
|---|---|
| PVC on `azurefile-nfs` Pending | `kubectl -n kube-system logs -l app=csi-azurefile-controller -c azurefile`; the cluster identity needs rights on the node RG / VNet (Terraform grants Network Contributor); Premium ZRS NFS available in the region? |
| `postgres-db-init` fails `could not connect` | private DNS zone linked to the VNet; NSG on `snet-postgres` allows 5432 from `snet-aks`; `kubectl -n platform-system get svc platform-postgres` points at the server FQDN |
| JupyterHub `sqlalchemy ... password authentication failed` | db-init not yet run after a password change → sync `platform-config` |
| ExternalSecret `SecretSyncedError` | `aiml-<env>-external-secrets` has *Key Vault Secrets User*; ESO pods carry `azure.workload.identity/use: "true"`; secret name exists in the vault |
| Blob `AuthorizationPermissionMismatch` from a pod | pod's SA must be one federated in `terraform/modules/workload-identity` (namespace:name exact match) and have a role on that container |
| Blob `AuthorizationFailure` (403) | storage firewall: request did not come from `snet-aks` (or your IP is not in `storage_allowed_ip_ranges`) |
| Pod has no `AZURE_FEDERATED_TOKEN_FILE` env | missing pod label `azure.workload.identity/use: "true"` or SA annotation `azure.workload.identity/client-id` |

## Ingress (Application Gateway / AGIC)

| Symptom | Fix |
|---|---|
| Ingress has no address | `kubectl -n kube-system logs deploy/ingress-appgw-deployment`; AGIC identity roles (Contributor on gateway, Reader on RG, Network Contributor on `snet-appgw`) |
| 502 from the gateway | backend health: Portal › Application Gateway › Backend health; health-probe path `/readyz` must return 200; pod IPs reachable (Overlay requires the delegated `/24` gateway subnet) |
| Changes to listeners/rules disappear | AGIC owns them — configure via Ingress annotations, never in the portal |

## Observability

| Symptom | Fix |
|---|---|
| Target missing in Prometheus | ServiceMonitor namespace/labels; kube-prometheus-stack selects all monitors (`*SelectorNilUsesHelmValues: false`) |
| Loki `no org id` / 401 | `auth_enabled: false` is set; check Alloy push URL `loki-gateway.monitoring` |
| Loki `AuthorizationPermissionMismatch` / token errors on Blob | SA `loki` annotation = client id of `aiml-<env>-loki`; `loki.podLabels` carries the Workload ID label; `useFederatedToken: true` |
| Elasticsearch `yellow` | normal for 1-node dev (replicas 0 via template only for new indices) |
| Kibana empty | create data view `logs-k8s-*`; check Logstash: `kubectl -n logging logs sts/logging-ls` |
| SLO panels "No data" | no traffic / pipeline runs in the window yet (ratio is undefined with 0 events) — generate load; check `slo:sli_error:ratio_rate` in Prometheus |
| Cost dashboard empty | `kubectl -n opencost logs deploy/opencost`; Prometheus target `opencost` UP; `node_total_hourly_cost` present; NodePool panels need KSM `metricLabelsAllowlist` (set in kube-prometheus-stack values) |
| Azure Monitor datasource errors | Grafana SA annotated with the `aiml-<env>-grafana` client id; `grafana.ini [azure] workload_identity_enabled = true`; Monitoring Reader on the subscription |
| Budget shows $0 for the env | tags reach Cost Management after ~24 h; resources must carry `Project` and `Environment` tags (AKS propagates cluster tags to the node RG, NAP VMs get them from the AKSNodeClass) |
| Grafana ES datasource 401 | `es-grafana-user` ExternalSecret synced? ES file realm user `grafana` exists: `kubectl -n logging get secret es-grafana-user` |

## ML

| Symptom | Fix |
|---|---|
| Inference `/readyz` 503 forever | no `latest.json` yet → run training pipeline; or Workload ID / Blob error in logs |
| `train` exit code 2 | quality gate failed — by design; inspect `metrics` artifact |
| RayJob never starts | `kubectl -n ray get rayjobs,pods`; KubeRay operator logs; worker resources fit the NodePool SKUs |
| `ModuleNotFoundError: trainer` in Ray | Ray image tag in `charts/ray-cluster/values-<env>.yaml` must be a built tag, not `bootstrap` |
| Pickle / sklearn version warning | training and inference requirements must pin identical scikit-learn/joblib/numpy |

## Security (DevSecOps)

| Symptom | Fix |
|---|---|
| Every ML pod rejected: `verify-ml-image-signatures` | image not signed by `build-and-deploy.yml@refs/heads/main` of *this* repo (fork/rename → update `signing.subject`), or Kyverno cannot read ACR: admission-controller pod lacks `AZURE_FEDERATED_TOKEN_FILE` / `image-verifier` lacks AcrPull |
| `restrict-image-registries` denies a platform sidecar | add the registry to `extraTrustedRegistries` in `charts/security-policies/values.yaml` (reviewed PR) |
| Trivy Operator reports `UNAUTHORIZED` pulling from ACR | scan-job pods need the Workload ID label (`trivyOperator.scanJobPodTemplateLabels`) and the `trivy-operator` SA client-id annotation |
| `terraform plan` fails in CI: conftest deny | read the message — e.g. prod needs `api_server_authorized_ip_ranges`; fix the tfvars, don't weaken `policy/terraform` |
| WAF blocks legitimate prediction batches (403) | `AGWFirewallLogs` → rule id; raise `waf.max_body_kb` or add a scoped exclusion in `terraform/modules/waf`; use `mode = "Detection"` in dev while tuning |
| AKS create fails: `KMS ... key vault` | `aks` identity needs *Key Vault Crypto User* (Terraform grants it) and the key must be enabled; Key Vault public access must stay on for public-mode KMS |
| `EncryptionAtHost` errors on node creation | feature not registered for the subscription (runbook Phase 0.2) or the VM SKU does not support it |
| Defender plan apply conflicts (`409`) | plans are applied sequentially; re-run the apply |
| Inference returns 401 for every call | `ml-inference-api-keys` secret synced? `kubectl -n ml-serving get externalsecret`; header name is `x-api-key` |
