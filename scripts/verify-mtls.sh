#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-app}"
FRONTEND_SELECTOR="${FRONTEND_SELECTOR:-app=frontend}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"
EXTERNAL_URL="${EXTERNAL_URL:-http://backend.${NAMESPACE}.svc.cluster.local:8080}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"

phase() {
  echo
  echo "==> $1"
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    exit 1
  fi
}

frontend_pod() {
  kubectl get pod -n "$NAMESPACE" -l "$FRONTEND_SELECTOR" \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' |
    awk '{print $1}'
}

require kubectl

phase "Checking that the frontend client is ready inside the mesh"
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l "$FRONTEND_SELECTOR" --timeout=120s
pod="$(frontend_pod)"
if [[ -z "$pod" ]]; then
  echo "ERROR: no running frontend pod found in namespace ${NAMESPACE}" >&2
  exit 1
fi
echo "Using in-mesh client pod: ${pod}"

phase "External plaintext request should fail under STRICT mTLS"
outside_pod="mtls-outside-$RANDOM"
if output="$(kubectl run "$outside_pod" \
  --namespace default \
  --rm \
  --attach \
  --quiet \
  --pod-running-timeout=120s \
  --restart=Never \
  --image "$CURL_IMAGE" \
  --command -- sh -c \
    'curl -sv --max-time 5 "$1"; status=$?; sleep 2; exit "$status"' \
    _ "$EXTERNAL_URL" 2>&1)"; then
  echo "$output"
  echo "ERROR: external request unexpectedly succeeded; STRICT mTLS is not proven." >&2
  exit 1
else
  echo "$output"
  echo "Expected failure observed for plaintext traffic from outside the mesh."
fi

phase "Internal mesh request should succeed"
kubectl exec -n "$NAMESPACE" "$pod" -c frontend -- curl -fsS --max-time 5 "$BACKEND_URL"
echo
echo "mTLS verification passed: outside plaintext failed, in-mesh request succeeded."
