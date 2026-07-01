#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-mesh-resilience-lab}"
NAMESPACE="${NAMESPACE:-app}"
ISTIO_PROFILE="${ISTIO_PROFILE:-demo}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    exit 1
  fi
}

phase() {
  echo
  echo "==> $1"
}

wait_for_deployment_if_present() {
  local namespace="$1"
  local deployment="$2"

  if kubectl get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
    kubectl rollout status "deployment/$deployment" -n "$namespace" --timeout=180s
  fi
}

require kind
require kubectl
require istioctl

phase "Ensuring kind cluster '${CLUSTER_NAME}' exists"
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster already exists; reusing it."
else
  kind create cluster --name "$CLUSTER_NAME"
fi

phase "Selecting Kubernetes context"
kubectl config use-context "kind-${CLUSTER_NAME}"

phase "Waiting for Kubernetes nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

phase "Installing or reconciling Istio (${ISTIO_PROFILE} profile)"
istioctl install --set "profile=${ISTIO_PROFILE}" -y

phase "Waiting for Istio control plane"
kubectl wait --for=condition=Ready pod -n istio-system -l app=istiod --timeout=180s
wait_for_deployment_if_present istio-system istiod
wait_for_deployment_if_present istio-system istio-ingressgateway
wait_for_deployment_if_present istio-system istio-egressgateway

phase "Applying lab manifests"
kubectl apply -f "${ROOT_DIR}/manifests"

phase "Waiting for application rollouts"
kubectl rollout status deployment/backend-v1 -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/backend-v2 -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=180s
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l app=backend --timeout=180s
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l app=frontend --timeout=180s

phase "Current application pods"
kubectl get pods -n "$NAMESPACE" -o wide

echo
echo "Setup complete. Run scripts/verify-mtls.sh, scripts/traffic-split-check.sh, and scripts/chaos-test.sh next."
