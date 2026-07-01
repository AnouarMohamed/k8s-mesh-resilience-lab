#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-app}"
JOB_NAME="${JOB_NAME:-k6-mesh-chaos}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-k6-loadtest}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:2.0.0}"
DELETE_SELECTOR="${DELETE_SELECTOR:-app=backend,version=v1}"

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

k6_pod() {
  kubectl get pod -n "$NAMESPACE" -l "job-name=${JOB_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
}

cleanup_previous_run() {
  kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true --wait=true
  kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true
}

require kubectl

phase "Preparing k6 ConfigMap"
cleanup_previous_run
kubectl create configmap "$CONFIGMAP_NAME" \
  --namespace "$NAMESPACE" \
  --from-file=loadtest.js="${ROOT_DIR}/loadtest/loadtest.js"

phase "Starting in-mesh k6 Job"
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: k6
      annotations:
        sidecar.istio.io/inject: "true"
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - k6
            - run
            - /scripts/loadtest.js
          volumeMounts:
            - name: loadtest
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: loadtest
          configMap:
            name: ${CONFIGMAP_NAME}
EOF

phase "Waiting for k6 pod to become ready"
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l "job-name=${JOB_NAME}" --timeout=180s
pod="$(k6_pod)"
echo "k6 pod: ${pod}"

phase "Deleting backend v1 pods while k6 is running"
kubectl delete pod -n "$NAMESPACE" -l "$DELETE_SELECTOR"

phase "Tailing k6 results"
set +e
kubectl logs -n "$NAMESPACE" "$pod" -c k6 -f
log_status=$?
set -e

phase "Cleaning up k6 Job"
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true --wait=true
kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true

if [[ "$log_status" -ne 0 ]]; then
  echo "ERROR: kubectl logs exited with status ${log_status}." >&2
  exit "$log_status"
fi

echo
echo "Chaos test finished. Inspect the k6 summary above for success and failure rates."
