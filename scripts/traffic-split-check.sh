#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-app}"
FRONTEND_SELECTOR="${FRONTEND_SELECTOR:-app=frontend}"
BACKEND_URL="${BACKEND_URL:-http://backend:8080}"
REQUESTS="${1:-${REQUESTS:-20}}"
EXPECTED_V1_PERCENT="${EXPECTED_V1_PERCENT:-90}"
EXPECTED_V2_PERCENT="${EXPECTED_V2_PERCENT:-10}"
TOLERANCE_PERCENT="${TOLERANCE_PERCENT:-25}"

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

if ! [[ "$REQUESTS" =~ ^[0-9]+$ ]] || [[ "$REQUESTS" -lt 1 ]]; then
  echo "ERROR: REQUESTS must be a positive integer." >&2
  exit 1
fi

phase "Waiting for frontend client"
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l "$FRONTEND_SELECTOR" --timeout=120s
pod="$(frontend_pod)"
if [[ -z "$pod" ]]; then
  echo "ERROR: no running frontend pod found in namespace ${NAMESPACE}" >&2
  exit 1
fi

phase "Sending ${REQUESTS} requests from ${pod}"
responses="$(
  kubectl exec -n "$NAMESPACE" "$pod" -c frontend -- sh -c '
    i=1
    while [ "$i" -le "$0" ]; do
      curl -fsS --max-time 5 "$1" || echo "request failed"
      i=$((i + 1))
    done
  ' "$REQUESTS" "$BACKEND_URL"
)"

v1_count="$(printf '%s\n' "$responses" | grep -c 'backend v1' || true)"
v2_count="$(printf '%s\n' "$responses" | grep -c 'backend v2' || true)"
failed_count="$(printf '%s\n' "$responses" | grep -c 'request failed' || true)"
total_count=$((v1_count + v2_count + failed_count))

if [[ "$total_count" -ne "$REQUESTS" ]]; then
  echo "$responses"
  echo "ERROR: expected ${REQUESTS} responses, counted ${total_count}." >&2
  exit 1
fi

if [[ "$failed_count" -ne 0 ]]; then
  echo "$responses"
  echo "ERROR: ${failed_count} requests failed during traffic split check." >&2
  exit 1
fi

v1_percent=$((100 * v1_count / REQUESTS))
v2_percent=$((100 * v2_count / REQUESTS))
v1_delta=$((v1_percent > EXPECTED_V1_PERCENT ? v1_percent - EXPECTED_V1_PERCENT : EXPECTED_V1_PERCENT - v1_percent))
v2_delta=$((v2_percent > EXPECTED_V2_PERCENT ? v2_percent - EXPECTED_V2_PERCENT : EXPECTED_V2_PERCENT - v2_percent))

echo "backend v1: ${v1_count}/${REQUESTS} (${v1_percent}%; expected about ${EXPECTED_V1_PERCENT}%)"
echo "backend v2: ${v2_count}/${REQUESTS} (${v2_percent}%; expected about ${EXPECTED_V2_PERCENT}%)"

if [[ "$v1_delta" -gt "$TOLERANCE_PERCENT" || "$v2_delta" -gt "$TOLERANCE_PERCENT" ]]; then
  echo "ERROR: observed split is outside +/- ${TOLERANCE_PERCENT}% tolerance." >&2
  exit 1
fi

echo "Traffic split check passed within sampling tolerance."
