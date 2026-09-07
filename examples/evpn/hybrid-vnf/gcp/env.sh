#!/bin/bash
#
# Discovers the live details of the GCP OpenShift cluster and exports them for
# the other scripts. Complements network.env (static choices) with values that
# depend on the actual cluster (infra ID, worker node names, worker subnet).
#
# Requires: oc (KUBECONFIG set to the cluster) and gcloud (authenticated to the
# project). Source it: `source ./env.sh`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/network.env"

# Infra ID / resource prefix. Everything the scripts create or touch on GCP is
# scoped to this, because the project is shared with other clusters.
CLUSTER_INFRA_ID="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')"
export CLUSTER_INFRA_ID
export GCP_NETWORK="${CLUSTER_INFRA_ID}-network"
export GCP_WORKER_SUBNET="${CLUSTER_INFRA_ID}-worker-subnet"

# Worker nodes, sorted; first is the route reflector, the rest are clients.
mapfile -t WORKER_NODES < <(oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
export WORKER_NODES
export RR_NODE="${WORKER_NODES[0]}"
export CLIENT_NODES=("${WORKER_NODES[@]:1}")

echo "Cluster infra ID : ${CLUSTER_INFRA_ID}"
echo "Project / region : ${GCP_PROJECT_ID} / ${GCP_REGION}"
echo "Network / subnet : ${GCP_NETWORK} / ${GCP_WORKER_SUBNET}"
echo "Route reflector  : ${RR_NODE}"
echo "Client nodes     : ${CLIENT_NODES[*]}"
