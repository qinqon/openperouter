#!/bin/bash
#
# Installs OpenPERouter on the GCP OpenShift cluster (Kubernetes mode) via Helm,
# from the chart in this repository, and grants the privileged SCC.
#
# Requires: helm, oc (KUBECONFIG set to the cluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../../../../charts/openperouter"

helm uninstall --ignore-not-found openperouter -n openperouter-system 2>/dev/null || true
helm install openperouter "${CHART_DIR}" \
    --namespace openperouter-system --create-namespace \
    -f "${SCRIPT_DIR}/values.yaml"

oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-controller
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-perouter

oc -n openperouter-system wait --for condition=established --timeout=60s \
    crd/l2vnis.network.openperouter.io \
    crd/underlays.network.openperouter.io

oc -n openperouter-system wait --for=condition=Ready --all pods --timeout=5m
