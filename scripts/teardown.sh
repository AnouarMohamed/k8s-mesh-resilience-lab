#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-mesh-resilience-lab}"

if ! command -v kind >/dev/null 2>&1; then
  echo "ERROR: missing required command: kind" >&2
  exit 1
fi

echo "==> Deleting kind cluster '${CLUSTER_NAME}' if it exists"
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "Cluster does not exist; nothing to delete."
fi
