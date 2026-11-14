#!/usr/bin/env bash
# Shift-left Kubernetes policy gate (used by CI and locally):
#  1. `kyverno test`  — unit tests: policies block bad pods and admit good ones
#  2. `kyverno apply` — our rendered ML workloads (prod values) must pass the same
#                        validate policies the cluster enforces at admission.
# (Signature verification needs the registry; it is enforced in-cluster and in promote-prod.yml.)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# render exactly what Argo CD deploys (cloudValues from the app-of-apps placeholders)
scripts/render-chart.sh template charts/security-policies prod > "$OUT/all-policies.yaml"
# drop the verifyImages policy (needs network + signed images) and NetworkPolicies
yq 'select(.kind == "ClusterPolicy" and .metadata.name != "verify-ml-image-signatures")' "$OUT/all-policies.yaml" > "$OUT/policies.yaml"

echo "== kyverno test (policy unit tests)"
cp charts/security-policies/tests/* "$OUT/"
kyverno test "$OUT"

echo "== kyverno apply (rendered ML workloads, prod values)"
scripts/render-chart.sh template charts/ml-inference prod -n ml-serving > "$OUT/inference.yaml"
yq 'select(.kind == "Deployment") | .metadata.namespace = "ml-serving"' "$OUT/inference.yaml" > "$OUT/workloads.yaml"
kyverno apply "$OUT/policies.yaml" --resource "$OUT/workloads.yaml" --policy-report --remove-color | tee "$OUT/report.txt"
if grep -Eq "fail: [1-9]|error: [1-9]" "$OUT/report.txt"; then
  echo "::error::rendered workloads violate cluster admission policies"; exit 1
fi
echo "policy gate passed"
