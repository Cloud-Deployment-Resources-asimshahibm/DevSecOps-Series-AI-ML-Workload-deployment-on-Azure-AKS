# Runbook — Deploying the AI/ML Platform on Azure AKS, DevSecOps edition (step by step)

> Audience: platform / DevOps engineer. Every step lists **what to run**, **what
> you should see**, and **what to do if you don't**. Run commands from the repo
> root unless stated otherwise. `ENV` is `dev` until Phase 11.
>
> 🔐 **DevSecOps edition.** Steps marked 🔐 are the security additions. Every gate is
> explained in [DEVSECOPS.md](DEVSECOPS.md). If you also run the DevOps edition, use a
> **separate subscription** (recommended), or change the `aiml` project prefix in
> `terraform/envs/*/terraform.tfvars` and `terraform/global` — otherwise resource names collide.

**Contents**

- [Phase 0 — Prerequisites](#phase-0--prerequisites)
- [Phase 1 — Configure the repository](#phase-1--configure-the-repository)
- [Phase 2 — Global layer: state, ACR, GitHub OIDC](#phase-2--global-layer-state-acr-github-oidc)
- [Phase 3 — GitHub configuration + first image build](#phase-3--github-configuration--first-image-build)
- [Phase 3A — 🔐 Security setup (GitHub + supply chain)](#phase-3a--security-setup)
- [Phase 4 — Provision the dev environment](#phase-4--provision-the-dev-environment)
- [Phase 5 — GitOps platform sync (what Argo CD installs, in order)](#phase-5--gitops-platform-sync)
- [Phase 6 — Secrets that need a human (JupyterHub OAuth)](#phase-6--secrets-that-need-a-human)
- [Phase 7 — Run the ML training pipeline](#phase-7--run-the-ml-training-pipeline)
- [Phase 8 — Validate inference + autoscaling](#phase-8--validate-inference--autoscaling)
- [Phase 9 — Validate observability](#phase-9--validate-observability)
- [Phase 9A — 🔐 Validate security controls](#phase-9a--validate-security-controls)
- [Phase 10 — Model development in JupyterHub (CPU, GPU, Ray)](#phase-10--model-development-in-jupyterhub)
- [Phase 11 — Production rollout](#phase-11--production-rollout)
- [Phase 12 — Day-2 operations](#phase-12--day-2-operations)
- [Phase 13 — Teardown](#phase-13--teardown)
- [Operational playbooks (alerts)](#operational-playbooks)

---

## Phase 0 — Prerequisites

### 0.1 Workstation tools

| Tool | Version | Check |
|---|---|---|
| Terraform | ≥ 1.10 | `terraform version` |
| Azure CLI | ≥ 2.67 | `az version` |
| kubelogin | ≥ 0.1.6 (Entra ID tokens for kubectl/Terraform) | `kubelogin --version` |
| kubectl | 1.32–1.34 | `kubectl version --client` |
| Helm | ≥ 3.16 | `helm version` |
| jq, yq (mikefarah v4) | latest | `jq --version; yq --version` |
| GitHub CLI | ≥ 2.50 | `gh --version` |
| Argo Workflows CLI | v3.6.x | `argo version` |
| Python | 3.12 (local tests) | `python3 --version` |

macOS: `brew install terraform azure-cli kubelogin kubectl helm jq yq gh argo`.
Linux/WSL: `az aks install-cli` installs kubectl + kubelogin.

### 0.2 Azure subscription

1. Use a subscription dedicated to this platform (or a sandbox). You need **Owner**
   (or Contributor + Role Based Access Control Administrator) because Terraform creates role assignments:
   ```bash
   az login
   az account set --subscription "<subscription name or id>"
   az account show --query '{sub:id, tenant:tenantId, user:user.name}' -o table
   ```
2. **Resource providers** (one-time per subscription):
   ```bash
   for ns in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Network \
             Microsoft.DBforPostgreSQL Microsoft.KeyVault Microsoft.Storage \
             Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.CostManagement Microsoft.Consumption; do
     az provider register --namespace $ns
   done
   ```
3. **vCPU quotas** in your region (default `eastus2`), Portal › *Quotas* › *Compute*:
   - *Standard NCASv3_T4 Family vCPUs* ≥ **8** (dev) — `Standard_NC4as_T4_v3` = 4 vCPU; add *NVADSA10v5* / *NCADS_A100_v4* for bigger GPUs.
   - *Standard DDSv5 / Dsv5 / Esv5 / Fsv2 Family vCPUs* ≥ 32 and *Total Regional Spot vCPUs* ≥ 32 (dev runs Spot first).
   ```bash
   az vm list-usage --location eastus2 -o table | grep -Ei "NCASv3_T4|DDSv5|Spot|Total Regional"
   ```
   Request increases now — GPU approval can take a day.
4. Your Entra ID object id (becomes AKS cluster-admin): `az ad signed-in-user show --query id -o tsv`.
5. 🔐 **Encryption at host** (system pool + NAP VMs) needs a one-time feature registration (takes a few minutes):
   ```bash
   az feature register --namespace Microsoft.Compute --name EncryptionAtHost
   az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state   # Registered
   az provider register --namespace Microsoft.Compute
   az provider register --namespace Microsoft.Security; az provider register --namespace Microsoft.PolicyInsights
   ```
6. 🔐 **Defender for Cloud / Azure Policy** are enabled by `terraform/global` (`security_services`). If your
   organization already manages Defender plans or policy at management-group level, set those flags to
   `false` in `terraform/global/terraform.tfvars` *before* Phase 2; set `security_contact_email`.

### 0.3 GitHub

- Repository: `Cloud-Deployment-Resources-asimshahibm/DevSecOps-Series-AI-ML-Workload-deployment-on-Azure-AKS`.
- Argo CD pulls this repo over HTTPS. If you make it **private**, add a read-only deploy key or token in Argo CD (`argocd repo add ...`) after Phase 4.

✅ **Exit criteria:** tools installed, `az account show` points at the right subscription, providers registered, quota requests submitted.

---

## Phase 1 — Configure the repository

```bash
git clone https://github.com/Cloud-Deployment-Resources-asimshahibm/DevSecOps-Series-AI-ML-Workload-deployment-on-Azure-AKS.git
cd DevSecOps-Series-AI-ML-Workload-deployment-on-Azure-AKS
make configure            # = scripts/configure.sh
```

`configure.sh` replaces three placeholders everywhere:

| Placeholder | Replaced with | Used in |
|---|---|---|
| `__SUBSCRIPTION_ID__` | `az account show --query id` | `terraform/*/terraform.tfvars` |
| `__ADMIN_OBJECT_ID__` | `az ad signed-in-user show --query id` | `cluster_admin_object_ids` (AKS RBAC Cluster Admin) |
| `__TFSTATE_STORAGE_ACCOUNT__` | `aimltfstate<suffix>` | `terraform/envs/*/backend.hcl` |

`<suffix>` = first 6 hex characters of `sha1(subscription id)`. Terraform computes the same
value for every globally unique name (`aiml<suffix>acr`, `aimldevdata<suffix>`, `aiml-dev-kv-<suffix>`),
so names are stable and nothing generated has to be copied into Git by hand. Everything
that *is* generated at apply time (managed-identity client ids, storage account, Key Vault URI,
ACR login server) reaches GitOps through Terraform → the Argo CD root app (`cloud:` values) →
each child app's `cloudValues` in `argocd/app-of-apps/values.yaml`.

Review and push — **Argo CD reads values from Git, so they must be committed before Phase 4**:

```bash
git diff --stat
git commit -am "chore: configure subscription"
git push origin main
```

Optional edits before pushing:

- `terraform/envs/*/terraform.tfvars` — `location`, `vnet_cidr`, VM sizes, `api_server_authorized_ip_ranges` (lock to your IP: `curl -s https://ifconfig.me`).
- `platform/jupyterhub/values.yaml` — `allowed_organizations`, `admin_users`.

✅ **Exit criteria:** `grep -rE "__SUBSCRIPTION_ID__|__ADMIN_OBJECT_ID__|__TFSTATE_STORAGE_ACCOUNT__" --exclude-dir=docs --exclude-dir=scripts .` returns nothing; changes pushed.

---

## Phase 2 — Global layer: state, ACR, GitHub OIDC

```bash
make global               # = scripts/bootstrap-global.sh
```

What happens:

1. `terraform apply` in `terraform/global` with local state creates, in resource group `aiml-global-rg`:
   - Storage account `aimltfstate<suffix>` + container `tfstate` — ZRS, versioning, soft delete, **shared keys disabled** (Entra ID auth only; Terraform locks state with blob leases)
   - Azure Container Registry `aiml<suffix>acr` (admin user disabled)
   - Managed identities `aiml-gha-tf-plan`, `aiml-gha-tf-apply`, `aiml-gha-ci` with **federated credentials** for this repo (pull requests, `main`, GitHub Environments `dev`/`prod`) and their role assignments
   - optional subscription cost anomaly alert (`billing_alert_emails`)
2. The script writes `terraform/global/backend.tf` and migrates the state into the storage account.
3. It prints the GitHub variables.

Verify:

```bash
az storage account list -g aiml-global-rg --query '[].name' -o tsv
az acr list -g aiml-global-rg --query '[].loginServer' -o tsv
az identity list -g aiml-global-rg --query '[].name' -o tsv
az identity federated-credential list -g aiml-global-rg --identity-name aiml-gha-ci --query '[].subject' -o tsv
```

Commit the generated backend file so teammates/CI use remote state:

```bash
git add terraform/global/backend.tf && git commit -m "chore: global remote state" && git push
```

❗ `AuthorizationPermissionMismatch` while migrating state → the *Storage Blob Data Contributor*
assignment is still propagating (up to 5 min); the script retries, or re-run `make global`.
❗ `ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity` → transient; re-run (the
module already serialises writes per identity).

✅ **Exit criteria:** three identities + ACR exist; state is in the storage account.

---

## Phase 3 — GitHub configuration + first image build

### 3.1 Repository variables (not secrets — they are just ids)

```bash
cd terraform/global
terraform output -json gha_variables | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
cd -
gh variable list
# AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_CLIENT_ID_TF_PLAN, AZURE_CLIENT_ID_TF_APPLY,
# AZURE_CLIENT_ID_CI, ACR_NAME, TFSTATE_STORAGE_ACCOUNT
```

### 3.2 GitHub Environments

Settings › Environments — the names must match the federated credentials (`environment:dev`, `environment:prod`):

| Environment | Protection |
|---|---|
| `dev` | none (or restrict to `main`) |
| `prod` | **Required reviewers** (you + 1), deployment branches: `main` only |

```bash
gh api -X PUT repos/{owner}/{repo}/environments/dev
gh api -X PUT repos/{owner}/{repo}/environments/prod
# then add reviewers for prod in the UI
```

### 3.3 Branch protection on `main`

Require PRs, **CODEOWNERS review**, signed commits (recommended), and these status checks (job names from `ci.yml`):

```
code · secret scanning (gitleaks)          code · SAST (Semgrep + Bandit)
code · dependencies (pip-audit + OSV)      code · dependency review (PR)
code · IaC & config scanning (Checkov + Trivy)
code · Kubernetes policy (Kyverno CLI, shift-left)
code · workflow security (actionlint + zizmor)
build · Dockerfile lint (hadolint)         test · unit + model-security tests
test · terraform validate + policy unit tests   test · helm lint + kubeconform
CodeQL
```

Under Settings › Code security, also add a **code scanning merge rule** that blocks on high and critical alerts.

### 3.4 Build images **before** the cluster exists

The Helm values ship with tag `bootstrap`. Building first means Argo CD deploys real images on its very first sync:

```bash
gh workflow run build-and-deploy.yml
gh run watch
```

Expected: 3 images pushed to ACR (`aiml/ml-inference`, `aiml/ml-training`, `aiml/ml-ray`, tag `<sha12>`),
Trivy passes, and a bot commit `deploy(dev): ml images <sha12>` updates `charts/*/values-dev.yaml`.

```bash
git pull
az acr repository show-tags -n "$(gh variable get ACR_NAME)" --repository aiml/ml-inference -o table
```

❗ `AADSTS700213: No matching federated identity record` → the subject does not match: repo name,
branch or Environment differs from what `terraform/global` was applied with (`github_org`, `github_repo`).
❗ *Trivy fails on CRITICAL*: bump the base image / pinned package in `ml/*/requirements.txt` and push again.

✅ **Exit criteria:** images in ACR, `values-dev.yaml` tags ≠ `bootstrap`.

---

## Phase 3A — Security setup

🔐 One-time settings that the security gates rely on.

1. **Code security features** (Settings › Code security): enable *Dependency graph*,
   *Dependabot alerts + security updates*, *Secret scanning + push protection*,
   *Private vulnerability reporting* and *Code scanning* (the workflows upload SARIF from
   gitleaks, Semgrep, Bandit, Checkov, Trivy, zizmor and CodeQL).
2. **Actions hardening** (Settings › Actions › General): *Workflow permissions = Read
   repository contents* (each job asks for more where it needs it). Leave *Allow GitHub
   Actions to create and approve pull requests* ticked only if you use `promote-prod.yml`.
3. **CODEOWNERS**: edit `.github/CODEOWNERS` and replace the placeholder teams with real
   users or teams. Security paths need their approval.
4. **Signing identity.** Kyverno only admits images signed by
   `https://github.com/<org>/<repo>/.github/workflows/build-and-deploy.yml@refs/heads/main`.
   If you fork or rename the repo, update `signing.subject` in
   `charts/security-policies/values.yaml`. If you don't, every ML pod is rejected (that is the point).
5. **Verify your first signed build** (from Phase 3.4):
   ```bash
   ACR="$(gh variable get ACR_NAME).azurecr.io"; az acr login -n "${ACR%%.*}"
   IMG="$ACR/aiml/ml-inference@$(yq '.image.digest' charts/ml-inference/values-dev.yaml)"
   REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
   cosign verify "$IMG" --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     --certificate-identity "https://github.com/$REPO/.github/workflows/build-and-deploy.yml@refs/heads/main" | jq '.[0].optional.Subject'
   gh attestation verify "oci://$IMG" --repo "$REPO"
   ```
   Expected: `Verification succeeded` and the workflow subject. In the portal, ACR › Repositories shows
   the signature, SBOM attestation and provenance as referrers of the digest.
6. **Defender for Cloud**: Portal › Microsoft Defender for Cloud › Environment settings › your
   subscription › *Defender plans* shows Containers, Storage, Key Vault, Open-source databases,
   Resource Manager and CSPM **On**; Regulatory compliance lists *CIS Microsoft Azure Foundations
   Benchmark v2.0.0* (data appears within ~24 h).

❗ *Build fails at "Gate: Trivy" or "Gate: Grype"*: a fixable HIGH/CRITICAL CVE. Upgrade the
package or base image. Add a time-boxed `.trivyignore` entry only with a reason
(see [DEVSECOPS.md §5](DEVSECOPS.md#5-exceptions-process)).

✅ **Exit criteria:** signed images with SBOM + provenance in ACR; all CI gates green on `main`; Defender plans on.

---

## Phase 4 — Provision the dev environment

First apply is done from your workstation (you watch it; later applies go through `terraform.yml`).

```bash
make deploy ENV=dev       # = scripts/deploy-env.sh dev
```

Under the hood:

```bash
cd terraform/stack
terraform init -backend-config=../envs/dev/backend.hcl
terraform plan -var-file=../envs/dev/terraform.tfvars -out=tfplan-dev
terraform apply tfplan-dev
az aks get-credentials -g aiml-dev-rg -n aiml-dev && kubelogin convert-kubeconfig -l azurecli
```

Resources created (≈ 110; 20–30 min, AKS + PostgreSQL + Application Gateway dominate):

| Order | Resource |
|---|---|
| 1 | Resource group `aiml-dev-rg`, Log Analytics `aiml-dev-law` |
| 2 | VNet `10.10.0.0/16`: `snet-aks` /20 (service endpoints Storage/KeyVault/ACR), `snet-appgw` /24 (delegated), `snet-postgres` /24 (delegated), `snet-endpoints` /24; NSGs; private DNS zone for PostgreSQL |
| 3 | Key Vault `aiml-dev-kv-<suffix>` (**Premium**, RBAC mode, audit logs to Log Analytics) + 🔐 HSM key `aks-etcd-kms` (rotation policy) |
| 4 | 🔐 WAF policy `aiml-dev-waf` (DRS 2.1, Bot Manager, per-IP rate limit, body cap) + Application Gateway `aiml-dev-appgw` (**WAF_v2**, autoscale, access + firewall logs) + public IP `aiml-dev-ml.<region>.cloudapp.azure.com` |
| 5 | AKS `aiml-dev`: system pool (2 × `Standard_D4ds_v5`, AzureLinux, ephemeral OS), **node auto-provisioning** (managed Karpenter), Azure CNI Overlay + Cilium (network policy), Entra ID + Azure RBAC, local accounts disabled, OIDC issuer + Workload ID, AGIC add-on, 🔐 **KMS etcd encryption**, **Defender sensor**, **Azure Policy add-on**, encryption at host, control-plane + audit logs → Log Analytics; 🔐 PSS-restricted policy assignment (audit) |
| 6 | Role assignments: AcrPull (kubelet), AGIC → gateway/subnet, cluster access (you, `gha-tf-apply`, `gha-tf-plan` custom read role, `gha-ci` cluster user) |
| 7 | Storage account `aimldevdata<suffix>` (shared keys off, firewall: AKS subnet only) — containers `data`, `models`, `artifacts`, `loki`; lifecycle rules |
| 8 | PostgreSQL Flexible Server 16 (private access) + Key Vault secrets `postgres-master`, `postgres-jupyterhub`, `postgres-argo-workflows` |
| 9 | Workload identities `aiml-dev-{ml-training,ml-inference,jupyter-user,argo-workflows,loki,grafana,external-secrets,image-verifier}` + federated credentials + data-plane roles (image-verifier: AcrPull for Kyverno + Trivy Operator) |
| 10 | Key Vault secrets `grafana-admin`, `jupyterhub-github-oauth`, `elasticsearch-grafana`, 🔐 `inference-api-keys`; 🔐 blob + PostgreSQL audit diagnostic settings |
| 11 | In-cluster (Helm/K8s providers): `azurefile-nfs` StorageClass, `platform-postgres` ExternalName service, Argo CD, **root Application `root-dev`** (with the `cloud:` facts) |
| 12 | Cost Management budgets `aiml-dev-total` / `aiml-dev-compute` (when `budgets.alert_emails` is set) |

Verify:

```bash
kubectl get nodes -L workload,kubernetes.azure.com/agentpool     # 2 × system Ready
kubectl get nodepools.karpenter.sh                               # none yet — they arrive via GitOps (Phase 5)
kubectl -n kube-system get deploy ingress-appgw-deployment       # AGIC add-on
kubectl -n argocd get applications                               # root-dev + children appearing
```

❗ Common first-apply issues:

| Symptom | Fix |
|---|---|
| `Kubernetes cluster unreachable` / `kubelogin` errors during helm releases | `az login` expired or kubelogin missing → `az login`, `az aks install-cli`; IP not in `api_server_authorized_ip_ranges` → fix tfvars |
| `Forbidden ... User "<oid>" cannot list resource` right after the cluster is created | Azure RBAC assignment still propagating (≤ 5 min) → re-run `make deploy ENV=dev` |
| `SubnetIsDelegated` / AGIC `ApplicationGatewaySubnetCannotBeUsedByOtherResources` | don't put anything but the gateway in `snet-appgw` |
| `EncryptionAtHost feature is not enabled` | Phase 0.2 step 5 (feature registration), then re-apply |
| `QuotaExceeded` creating the system pool | vCPU quota for `Dds_v5` in the region (Phase 0.2) or choose another `system_node_pool.vm_size` |
| `KeyVaultAlreadyExists` / `VaultAlreadySoftDeleted` after a destroy | `az keyvault purge -n aiml-dev-kv-<suffix>` (dev only), then re-apply |
| Apply interrupted | just re-run `make deploy ENV=dev`; Terraform is idempotent |

✅ **Exit criteria:** `terraform apply` complete; `root-dev` exists in Argo CD.

---

## Phase 5 — GitOps platform sync

```bash
make wait                 # live table of Applications until all Synced/Healthy (15–25 min)
make access               # port-forwards + prints credentials
```

Argo CD UI → http://localhost:8080 (user `admin`, password printed by `make access`).

Sync order (sync-waves) and what to check in each:

| Wave | Application | Namespace | Check |
|---|---|---|---|
| -30 | `karpenter-nodepools` | kube-system | `kubectl get nodepools,aksnodeclasses` → `cpu`, `gpu`; AKSNodeClass `Ready` |
| -30 | `kyverno` | kyverno | admission controller Running; 🔐 pod env has `AZURE_FEDERATED_TOKEN_FILE` (ACR credential helper) |
| -30 | `external-secrets` | external-secrets | pods Running; pod env has `AZURE_FEDERATED_TOKEN_FILE` (Workload ID injected) |
| -28 | `security-policies` | kyverno | `kubectl get clusterpolicy` → all `READY=True` |
| -25 | `platform-config` | platform-system (+ others) | `kubectl get clustersecretstore azure-key-vault` Valid; `kubectl get externalsecrets -A` all `SecretSynced`; Job `postgres-db-init` Completed |
| -20 | `kube-prometheus-stack` | monitoring | Prometheus, Alertmanager, Grafana Running (node auto-provisioning launches the first `ml-cpu` VM here) |
| -15 | `loki`, `eck-operator`, `gpu-operator`, `kuberay-operator` | … | operators Running; Loki writes to the `loki` container |
| -10 | `alloy`, `observability-extras`, `elastic-stack`, `argo-workflows`, `opencost`, `observability-rules`, 🔐 `falco`, `trivy-operator`, `policy-reporter` | … | ES `green`/`yellow`, Kibana up, Argo WF server up, Falco DaemonSet ready, first VulnerabilityReports appear |
| -5 | `jupyterhub` | jupyterhub | `hub` + `proxy` Running (hub may CrashLoop until Phase 6) |
| 0 | `ray-cluster`, `ml-pipelines`, `ml-inference` | ray, ml-training, ml-serving | RayCluster `ready`; WorkflowTemplate exists; inference pods **not Ready yet** (no model) — expected |

Watch node auto-provisioning create capacity (Karpenter runs in the AKS-managed control plane,
so there are no controller logs in the cluster — use NodeClaims and events):

```bash
kubectl get nodeclaims -w
kubectl get events -A --field-selector source=karpenter -w
```

See what Argo CD injected from Terraform into a child app:

```bash
kubectl -n argocd get application ml-inference -o jsonpath='{.spec.source.helm.valuesObject}' | jq
```

Validate the database bootstrap:

```bash
kubectl -n platform-system logs job/postgres-db-init
# ensuring role/database jupyterhub ... ensuring role/database argo_workflows ... done
```

❗ If an app is stuck: Argo CD UI › app › *Sync status* / *Events*, or see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

✅ **Exit criteria:** all apps Synced/Healthy except `ml-inference` (Progressing until Phase 7) and possibly `jupyterhub` (until Phase 6).

---

## Phase 6 — Secrets that need a human

### 6.1 JupyterHub GitHub OAuth app

1. GitHub › Org settings › Developer settings › **OAuth Apps › New**.
   - Homepage: `http://localhost:8000` (dev) / `https://jupyter.<your-domain>` (prod)
   - Callback: `http://localhost:8000/hub/oauth_callback` (dev) — must match `platform/jupyterhub/values-dev.yaml`
2. Store credentials in Key Vault (never in Git):
   ```bash
   KV=$(terraform -chdir=terraform/stack output -raw key_vault_name)
   az keyvault secret set --vault-name "$KV" --name jupyterhub-github-oauth \
     --value '{"client_id":"<id>","client_secret":"<secret>"}' --content-type application/json -o none
   ```
3. Force External Secrets to refresh and restart the hub:
   ```bash
   kubectl -n jupyterhub annotate externalsecret jupyterhub-github-oauth force-sync=$(date +%s) --overwrite
   kubectl -n jupyterhub rollout restart deploy/hub
   ```

### 6.2 Alertmanager receiver (recommended)

Add a Slack/PagerDuty/Teams receiver in `observability/kube-prometheus-stack/values.yaml`
(`alertmanager.config.receivers`) — keep the webhook URL in Key Vault and mount it via an
ExternalSecret. Commit → Argo CD syncs.

✅ **Exit criteria:** `jupyterhub` app Healthy; login page shows *Sign in with GitHub*.

---

## Phase 7 — Run the ML training pipeline

Option A — GitHub Actions (recommended, auditable):

```bash
gh workflow run run-training-pipeline.yml -f environment=dev -f use_ray=true -f auto_promote=true
gh run watch
```

Option B — CLI:

```bash
argo submit -n ml-training --from workflowtemplate/ml-training-pipeline \
  -p use-ray=true -p auto-promote=true --watch
```

Pipeline DAG:

```
validate-data ──► hyperparameter-tuning (RayJob on ml-ray, 16 trials) ──► train ──► [approval] ──► promote
```

Watch it:

| Where | How |
|---|---|
| Argo Workflows UI | `make access` → http://localhost:2746 › ml-training |
| Ray dashboard | http://localhost:8265 — jobs, trials, worker autoscaling (node auto-provisioning adds `ml-cpu` VMs) |
| Logs | Grafana › Explore › Loki: `{namespace="ml-training"} \| json` |

Verify the registry (`az://<account>/models`):

```bash
SA=$(terraform -chdir=terraform/stack output -raw storage_account)
az storage blob download --account-name "$SA" -c models -n iris-classifier/latest.json --auth-mode login -f /dev/stdout -o none
# {"version": "...", "previous": null}
az storage blob list --account-name "$SA" -c models --prefix iris-classifier/ --auth-mode login --query '[].name' -o tsv
```

(The storage firewall only admits the AKS subnet. To browse from your laptop add your IP to
`storage_allowed_ip_ranges` in the tfvars, or run the commands from a pod — you also need
*Storage Blob Data Reader* on the account.)

Within `MODEL_REFRESH_SECONDS` (30 s in dev) the inference pods load the model and become Ready:

```bash
kubectl -n ml-serving get pods -w
kubectl -n ml-serving logs deploy/ml-inference | grep '"model loaded"'
```

❗ `train` exits 2 → quality gate failed (accuracy < `min-accuracy`). Look at the `metrics` artifact; nothing was promoted, serving is untouched.
❗ `hyperparameter-tuning` stuck *Pending* → RayJob waiting for workers: `kubectl -n ray get pods`, `kubectl get nodeclaims` (quota? Spot capacity?).
❗ `ClientAuthenticationError` / `AuthorizationPermissionMismatch` from Blob → Workload ID: see [MLInferenceModelNotLoaded](#mlinferencemodelnotloaded-critical).

✅ **Exit criteria:** workflow Succeeded; `latest.json` exists; `ml-inference` Healthy.

---

## Phase 8 — Validate inference + autoscaling

```bash
GW=$(kubectl -n ml-serving get ingress ml-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# or the stable name: terraform -chdir=terraform/stack output -raw app_gateway_fqdn
API_KEY=$(kubectl -n ml-serving get secret ml-inference-api-keys -o jsonpath='{.data.api-keys}' | base64 -d | head -1)
curl -s http://$GW/v1/models -H "x-api-key: $API_KEY" | jq '.version, .metadata.metrics'
curl -s http://$GW/v1/predict -H 'content-type: application/json' -H "x-api-key: $API_KEY" \
  -d '{"instances": [[5.1,3.5,1.4,0.2],[6.7,3.0,5.2,2.3]]}' | jq
# -> setosa, virginica
curl -s -o /dev/null -w '%{http_code}\n' http://$GW/v1/predict -d '{}'   # -> 401 without a key
```

Swagger UI: `http://$GW/docs` (dev only; `security.enableDocs: false` in prod).

Load test → HPA → node auto-provisioning:

```bash
kubectl run load --rm -it --image=williamyeh/hey --restart=Never -- \
  -z 5m -c 50 -m POST -T application/json -H "x-api-key: $API_KEY" \
  -d '{"instances": [[5.1,3.5,1.4,0.2]]}' http://ml-inference.ml-serving/v1/predict
# second terminal
kubectl -n ml-serving get hpa -w
kubectl get nodeclaims -w
```

Expected: HPA scales replicas up; if pods don't fit, NAP creates a VM within ~1–2 min; after the
test, replicas scale down after 5 min and NAP consolidates the node.

Run the full smoke test:

```bash
make smoke ENV=dev
```

✅ **Exit criteria:** predictions correct; HPA + node auto-provisioning react; smoke test passes.

---

## Phase 9 — Validate observability

1. **Grafana** (http://localhost:3000): folder *ML Platform* →
   - *ML Inference — API & Model*: RPS, error ratio, p95, served version, confidence, logs panel.
   - *ML Platform — GPU, Node auto-provisioning, Pipelines, Ray, JupyterHub*.
   - Built-in *Kubernetes / Compute Resources* dashboards.
   - Datasource *Azure Monitor* (Workload ID, Monitoring Reader): Explore › Azure Monitor › Application Gateway / PostgreSQL / Storage metrics.
2. **Prometheus** (http://localhost:9090 › Status › Targets): `ml-inference`, `argocd`, `argo-workflows`, `ml-ray`, `dcgm-exporter` (when a GPU node exists), `loki`, `alloy`, `kube-state-metrics` all **UP**. Node auto-provisioning state comes from kube-state-metrics: query `karpenter_nodepool_usage_cpu` and `karpenter_nodeclaim_condition`.
3. **Alerts**: Prometheus › Alerts shows `ml-inference.slo`, `gpu`, `karpenter`, `pipelines`, `gitops`, `secrets` groups. Fire a test:
   ```bash
   kubectl -n monitoring exec sts/alertmanager-kube-prometheus-stack-alertmanager -- \
     amtool alert add test severity=warning --annotation=summary="runbook test" --alertmanager.url=http://localhost:9093
   ```
4. **Loki**: Grafana › Explore › Loki:
   ```logql
   {namespace="ml-serving"} | json | status >= 400
   sum by (level) (count_over_time({namespace=~"ml-.*"} | json [5m]))
   ```
5. **SLO / error budgets**: Grafana › SRE › *ML Platform — SLO / SLI & Error Budgets*. All 5 SLOs listed with objective and budget. They read "No data" until there is traffic/runs — generate some with the Phase 8 load test and Phase 7 pipeline. Check the rules are loaded:
   ```bash
   kubectl -n monitoring get prometheusrule slo-error-budgets cost-allocation
   # Prometheus UI: query  slo:error_budget_remaining:ratio  and  slo:burn_rate{window="1h"}
   ```
   Fire a burn-rate alert on purpose (dev): pin a missing version `model.version: does-not-exist`
   in `charts/ml-inference/values-dev.yaml` → push → `SLOErrorBudgetBurn{slo="ml-model-freshness"}` goes pending. Revert afterwards.
6. **Performance**: Grafana › ML Platform › *ML Platform — Performance* — during the Phase 8 load test watch p95/p99, Apdex, CPU vs request (HPA target 65 %), throttling, HPA replicas, NodeClaim launch time and bin-packing.
7. **Cost & billing**:
   - OpenCost: `kubectl -n opencost port-forward svc/opencost 9091:9090` → http://localhost:9091 (allocation UI); metrics after ~10 min: query `node_total_hourly_cost`.
   - Grafana › FinOps › *ML Platform — Cost & Billing*: run-rate, projection vs budget, namespace table, NodePool, Spot vs on-demand, GPU unallocated, cost per 1k predictions.
   - The real invoice: Portal › *Cost Management* › *Cost analysis*, filter tag `Project = aiml`, group by tag `Environment` / `nodepool` (tags appear ~24 h after resources are created).
   - Budgets: `az consumption budget list --query '[].name' -o tsv` → `aiml-dev-total`, `aiml-dev-compute` (created when `budgets.alert_emails` is non-empty in `terraform/envs/dev/terraform.tfvars`).
8. **ELK**: Kibana (http://localhost:5601, user `elastic`, password from `make access`) › Stack Management › Data Views › create `logs-k8s-*` (time field `@timestamp`) › Discover:
   `k8s.namespace : "ml-serving" and app.msg : "model loaded"`.
   ILM: Stack Management › Index Lifecycle Policies › `logs-k8s` (7 d in dev).
9. **Control plane** (Log Analytics `aiml-dev-law`): API server audit logs, e.g.
   ```kusto
   AKSAuditAdmin | where TimeGenerated > ago(1h) | summarize count() by Verb, User=tostring(User.username) | top 20 by count_
   ```

✅ **Exit criteria:** dashboards populated (Inference, Platform, Performance, SLO, Cost & Billing), all targets UP incl. `opencost`, test alert visible in Alertmanager, logs searchable in Loki and Kibana, budgets exist.

---

## Phase 9A — Validate security controls

🔐 Prove each runtime control works. Don't just trust that it is installed.

1. **Enable DAST** (once per environment):
   ```bash
   GW=$(terraform -chdir=terraform/stack output -raw app_gateway_fqdn)
   KV=$(terraform -chdir=terraform/stack output -raw key_vault_name)
   gh variable set DEV_INFERENCE_URL --body "http://$GW"
   gh secret set DAST_API_KEY --body "$(az keyvault secret show --vault-name "$KV" -n inference-api-keys --query value -o tsv | jq -r .keys)"
   gh workflow run dast.yml && gh run watch
   ```
   Expected: the DAST run is green (it scans through the WAF).
2. **WAF blocks attacks at the edge:**
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' "http://$GW/v1/models?q=<script>alert(1)</script>" -H "x-api-key: $API_KEY"   # 403
   curl -s -o /dev/null -w '%{http_code}\n' "http://$GW/v1/models" -H 'User-Agent: ${jndi:ldap://x/a}'                   # 403 (Log4Shell)
   ```
   Log Analytics: `AGWFirewallLogs | where Action == "Blocked" | take 20`.
3. **Admission control rejects untrusted images:**
   ```bash
   kubectl -n ml-serving run probe --image=mcr.microsoft.com/azurelinux/busybox:1.36 --restart=Never -- sleep 60
   # Error from server: admission webhook ... denied the request: ... verify-ml-image-signatures / restrict-image-registries
   kubectl -n ml-serving run probe2 --image="$ACR/aiml/ml-inference:latest" --restart=Never
   # denied: disallow-latest-tag
   ```
4. **Pod security:** a pod with `runAsUser: 0` in `ml-serving` is denied by `ml-restricted-pod-security` and by
   Pod Security Admission; Azure Policy reports it in Defender for Cloud › Recommendations within ~30 min (audit).
5. **Runtime detection (Falco + Defender):**
   ```bash
   POD=$(kubectl -n ml-serving get pod -l app.kubernetes.io/name=ml-inference -o name | head -1)
   kubectl -n ml-serving exec "$POD" -- sh -c 'id' 2>/dev/null || true
   ```
   Within ~1 min: Loki `{priority="Critical"}` shows *Shell spawned in model-serving container* and
   `FalcoCriticalEvent` fires. Defender for Containers raises its own alert for suspicious exec
   activity (Defender for Cloud › Security alerts, may take ~15 min).
6. **Model integrity:** publish a tampered copy of the current model as a new version and point the
   registry at it (dev only):
   ```bash
   SA=$(terraform -chdir=terraform/stack output -raw storage_account)
   CUR=$(az storage blob download --account-name "$SA" -c models -n iris-classifier/latest.json --auth-mode login -f /dev/stdout -o none | jq -r .version)
   for f in metadata.json security.json; do
     az storage blob copy start --account-name "$SA" --auth-mode login --destination-container models \
       --destination-blob "iris-classifier/tamper-test/$f" --source-container models --source-blob "iris-classifier/$CUR/$f" -o none
   done
   echo "not the trained model" | az storage blob upload --account-name "$SA" --auth-mode login -c models -n iris-classifier/tamper-test/model.pkl --data @- --overwrite -o none
   jq -n --arg p "$CUR" '{version:"tamper-test",previous:$p}' | az storage blob upload --account-name "$SA" --auth-mode login -c models -n iris-classifier/latest.json --data @- --overwrite -o none
   ```
   Within the refresh interval the pods log `model rejected by integrity check`, keep serving `$CUR`,
   and `ModelArtifactIntegrityFailure` fires. `StorageBlobLogs` in Log Analytics shows who wrote the blobs.
   Clean up: point `latest.json` back at `$CUR` and delete `iris-classifier/tamper-test/`.
   (Run these from an IP in `storage_allowed_ip_ranges`, with *Storage Blob Data Contributor* on the account.)
7. **Secrets encryption:** `az aks show -g aiml-dev-rg -n aiml-dev --query securityProfile.azureKeyVaultKms`
   → `enabled: true`, key id of `aks-etcd-kms`.
8. **Continuous scanning:** `kubectl get vulnerabilityreports,configauditreports,exposedsecretreports -n ml-serving`
   lists reports for every workload; Grafana › Security › *Security Posture* is populated; Defender for Cloud ›
   Recommendations › *Azure registry container images should have vulnerabilities resolved* lists ACR findings.
9. `make smoke ENV=dev`. The **Security** section must be all PASS.

✅ **Exit criteria:** WAF blocks XSS/Log4Shell; untrusted, unsigned, `latest` and root pods are rejected; Falco + integrity alerts fire on demand; KMS enabled; DAST green; Defender alerts and recommendations visible.

---

## Phase 10 — Model development in JupyterHub

1. `make access` → http://localhost:8000 → *Sign in with GitHub* (must be in the allowed org).
2. Choose a profile:
   - **CPU — small / large**: lands on `ml-cpu` auto-provisioned VMs.
   - **GPU — 1× T4/A10**: NAP launches an NC/NV VM (4–6 min cold start), the GPU operator advertises `nvidia.com/gpu`.
3. In a notebook:
   ```python
   # GPU check (GPU profile)
   import torch; torch.cuda.is_available(), torch.cuda.get_device_name(0)

   # Blob through Workload ID — no keys (pip install azure-identity azure-storage-blob)
   from azure.identity import DefaultAzureCredential
   from azure.storage.blob import BlobServiceClient
   svc = BlobServiceClient("https://<storage-account>.blob.core.windows.net", DefaultAzureCredential())
   [b.name for b in svc.get_container_client("models").list_blobs()][:5]

   # Distributed compute on the shared Ray cluster (RAY_ADDRESS is preset)
   import ray; ray.init()
   @ray.remote
   def square(x): return x * x
   ray.get([square.remote(i) for i in range(100)])[:5]
   ```
   Your client Python/Ray versions should match the cluster image (Ray 2.40, Python 3.12) for Ray Client; for heavy jobs prefer submitting a RayJob or an Argo Workflow.
4. Storage: `~/` is your Azure Files NFS home (survives restarts); `~/shared` is the team volume.
5. Idle servers are culled after 1 h (dev) → nodes consolidate → cost back to baseline.

✅ **Exit criteria:** CPU and GPU servers start; Blob and Ray calls succeed.

---

## Phase 11 — Production rollout

1. **Harden `terraform/envs/prod/terraform.tfvars`**:
   - `api_server_authorized_ip_ranges` → your VPN/office CIDRs (and your CI runners' egress, or use self-hosted runners in the VNet).
     🔐 **Required**: the OPA policy `policy/terraform` *denies* the prod plan while it is empty
     (`prod AKS API server must restrict authorized IP ranges`).
   - 🔐 with self-hosted runners in the VNet: `key_vault_default_action = "Deny"` (see DEVSECOPS.md accepted risks).
   - review VM sizes, PostgreSQL SKU, `app_gateway` capacity.
2. **DNS/TLS**: create a CNAME `api.<your-domain>` / `jupyter.<your-domain>` → `terraform output app_gateway_fqdn`;
   provide the certificates as Kubernetes TLS secrets (cert-manager or your PKI); set `ingress.host` +
   `ingress.tlsSecretName` in `charts/ml-inference/values-prod.yaml` and the host/TLS in `platform/jupyterhub/values-prod.yaml`.
3. Open a PR with these changes → `terraform.yml` posts the **prod plan** → review → merge.
4. Apply prod (environment approval required):
   ```bash
   gh workflow run terraform.yml -f environment=prod
   ```
   Approve in the Actions UI. The first prod apply takes ~35 min (zone-redundant PostgreSQL HA).
5. Add a kube context and wait for GitOps:
   ```bash
   az aks get-credentials -g aiml-prod-rg -n aiml-prod --context aiml-prod && kubelogin convert-kubeconfig -l azurecli
   scripts/wait-for-apps.sh aiml-prod
   ```
6. Repeat Phase 6 for prod secrets (Key Vault `aiml-prod-kv-<suffix>`, secret `jupyterhub-github-oauth`).
7. **Promote images** dev → prod:
   ```bash
   gh workflow run promote-prod.yml           # opens PR "deploy(prod): verified ml images <tag>"
   ```
   🔐 The workflow first re-verifies every dev **digest**: cosign signature, SLSA
   provenance, a fresh Trivy scan with today's CVE data, and the last DAST run. Only then
   does it open the PR. Complete the checklist (Security Posture dashboard and Defender alerts clean
   in dev), get CODEOWNERS approval and merge. Argo CD in prod syncs **inside the change window**
   (syncs are denied 22:00–06:00 UTC; manual sync is allowed for hotfixes).
8. Train in prod: nightly CronWorkflow runs at 03:00 UTC with `auto-promote=false`; approve promotion:
   ```bash
   argo -n ml-training list
   argo -n ml-training resume <workflow-name>     # after reviewing metrics
   ```
   or trigger now: `gh workflow run run-training-pipeline.yml -f environment=prod -f auto_promote=false`.
9. `kubectl config use-context aiml-prod && make smoke ENV=prod`.

✅ **Exit criteria:** prod smoke test green; promotion PR merged; model served in prod.

---

## Phase 12 — Day-2 operations

| Task | Procedure |
|---|---|
| **Deploy new model code** | PR to `ml/` → merge → dev auto-deploys → `promote-prod.yml` PR |
| **Retrain** | `run-training-pipeline.yml` or wait for nightly CronWorkflow |
| **Rotate inference API keys** 🔐 | add a key line to Key Vault `inference-api-keys` (`{"keys":"old\nnew"}`) → clients switch → remove the old key; ESO refreshes in ≤ 15 min |
| **Review security posture (weekly)** 🔐 | Defender for Cloud secure score + new recommendations; Grafana *Security Posture*; open Dependabot / code-scanning alerts; `.trivyignore` / `.checkov.yaml` exceptions approaching expiry |
| **Roll back a model** (seconds, no deploy) | `kubectl -n ml-training run rollback --rm -it --restart=Never --labels=azure.workload.identity/use=true --overrides='{"spec":{"serviceAccountName":"ml-training"}}' --image=<acr>.azurecr.io/aiml/ml-training:<tag> -- trainer.promote --model-store az://<storage-account>/models --rollback` |
| **Pin a model version** | set `model.version: <version>` in `charts/ml-inference/values-<env>.yaml` → PR |
| **Roll back app/chart** | `git revert <deploy commit>` → Argo CD syncs |
| **Upgrade a platform component** | bump `chart.version` in `argocd/app-of-apps/values.yaml` → PR → dev → prod |
| **Upgrade AKS** | patch versions are automatic (`automatic_upgrade_channel = patch`); minor: bump `kubernetes_version` (one minor at a time) → PR → apply dev → verify → prod. NAP replaces nodes via drift. |
| **Node patching** | `node_os_upgrade_channel = NodeImage` (system pool); NAP `expireAfter: 720h` recycles VMs monthly onto the latest node image |
| **Scale limits** | `charts/karpenter-nodepools/values-<env>.yaml` → `limits` |
| **Rotate PostgreSQL app passwords** | `terraform apply -replace='module.database.random_password.app["jupyterhub"]'` → ESO syncs → re-sync `platform-config` (db-init re-applies) → restart hub |
| **Grafana admin password** | `az keyvault secret show --vault-name aiml-<env>-kv-<suffix> -n grafana-admin --query value -o tsv \| jq -r '."admin-password"'` |
| **Backups** | PostgreSQL automated backups (7 d dev / 14 d prod, geo-redundant in prod) + point-in-time restore; Blob versioning + soft delete; Key Vault soft delete (+ purge protection in prod); Git is the backup for everything else |
| **Restore PostgreSQL** | `az postgres flexible-server restore --source-server aiml-<env>-pg --restore-time <UTC> -n aiml-<env>-pg-restored -g aiml-<env>-rg` → point the ExternalName (`postgres_fqdn`) at the new server via Terraform → restart hub/argo-server |
| **Cost review (weekly)** | Grafana *Cost & Billing*: top namespaces, idle ratio, unallocated GPU, Spot share, cost per 1k predictions; Cost Management › Cost analysis grouped by tag `Environment` / `nodepool`; adjust `cost.monthlyBudgetUSD` + Terraform `budgets` together |
| **SLO review (weekly)** | Grafana *SLO / Error Budgets*: budget remaining per SLO; apply the [error budget policy](OBSERVABILITY.md#error-budget-policy); tune objectives in `charts/observability-rules/values.yaml` via PR |

---

## Phase 13 — Teardown

```bash
make destroy ENV=dev        # = scripts/teardown.sh dev
```

Order: delete root app (cascade) → delete Ingresses/LoadBalancer Services (AGIC removes its gateway rules) → delete NodePools (NAP deletes its VMs) → `terraform destroy`.

Leftovers by design: Azure Files data for PVCs with `reclaimPolicy: Retain` (deleted with the node
resource group), soft-deleted Key Vault (purge-protected in prod), ACR images and the state
storage account (global layer). Remove the global layer last, only if you are done with every env:

```bash
cd terraform/global && terraform destroy
```

---

## Operational playbooks

### <a id="ops-high-error-rate"></a>MLInferenceHighErrorRate (critical)

1. Grafana › *ML Inference*: which status codes, since when, which version (`Served model version` panel)?
2. Recent changes: `kubectl -n argocd get application ml-inference -o jsonpath='{.status.history[-1]}'`; the registry pointer `models/<name>/latest.json` (Phase 7).
3. Logs: Loki `{namespace="ml-serving"} | json | level="error"`.
4. If a new model caused it → **model rollback** (Phase 12). If a new image → `git revert` the deploy commit.

### MLInferenceModelNotLoaded (critical)

1. `kubectl -n ml-serving logs deploy/ml-inference | grep "model load failed"`.
2. `ClientAuthenticationError` / `AADSTS70021` → Workload ID: does the SA annotation `azure.workload.identity/client-id` equal `terraform output workload_identity_client_ids["ml-inference"]`? Does the pod have `AZURE_FEDERATED_TOKEN_FILE` in its env (label `azure.workload.identity/use: "true"`)? Is there a federated credential for `system:serviceaccount:ml-serving:ml-inference`?
3. `AuthorizationPermissionMismatch` → role assignment (Storage Blob Data Reader on `models`) missing or still propagating; `AuthorizationFailure` → storage firewall (pod not in `snet-aks`?).
4. `BlobNotFound latest.json` → no model promoted yet → run Phase 7.

### KarpenterNodeClaimLaunchFailures / PodsPendingTooLong

1. `kubectl describe nodeclaim <name>` and `kubectl get events -A --field-selector source=karpenter`.
2. `QuotaExceeded` / `OperationNotAllowed ... vCPUs` → quota increase for that VM family; `SkuNotAvailable` / `AllocationFailed` → add SKUs/families to the NodePool or another zone; Spot evictions → allow `on-demand` in `capacityTypes`; NodePool `limits` reached → raise limits.

### SLOErrorBudgetBurn (critical = page, warning = ticket)

1. Open the SLO dashboard (`dashboard` annotation) for the `slo` label; check which windows are burning.
2. Correlate with *Performance* (latency, errors, saturation) and recent changes (Argo CD history, `latest.json`).
3. Mitigate first: model rollback / `git revert` / scale out (`autoscaling.maxReplicas`). Then root-cause.
4. If the budget is exhausted, apply the [error budget policy](OBSERVABILITY.md#error-budget-policy) (freeze promotions for that service).

### CostMonthlyProjectionOverBudget / CostHourlySpike / CostUnallocatedGPU

1. Grafana *Cost & Billing* → which namespace / NodePool / VM size moved?
2. GPU: `kubectl get nodeclaims -l karpenter.sh/nodepool=gpu`; idle notebook servers (`kubectl -n jupyterhub get pods`), finished RayJobs still holding workers (`kubectl -n ray get pods`).
3. Idle ratio high: compare requests vs usage on *Performance* (CPU vs request) and right-size requests.
4. Legit growth → raise `cost.monthlyBudgetUSD` and Terraform `budgets` in the same PR.

### GPUXidErrors

Cordon and drain the node, then delete its NodeClaim — NAP replaces it:
`kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data && kubectl delete nodeclaim <claim>`.

### ExternalSecretSyncFailing

`kubectl describe externalsecret -n <ns> <name>` → `Forbidden` / `does not have secrets get permission` (Key Vault Secrets User missing for `aiml-<env>-external-secrets`), `SecretNotFound` (Key Vault secret name), or token errors (Workload ID, see above). Fix in Terraform/Git; force refresh with the `force-sync` annotation.

### ArgoCDAppDegraded / OutOfSync

Argo CD UI › app › diff + events. A failing hook (e.g. `postgres-db-init`) shows under *Sync status* — `kubectl logs job/<hook>`. Never `kubectl edit` live resources; fix in Git (self-heal will revert manual changes).
