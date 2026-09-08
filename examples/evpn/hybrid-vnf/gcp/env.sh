#!/bin/bash
#
# Discovers the live details of the GCP OpenShift cluster and exports them for
# the other scripts. Complements network.env (static choices) with values that
# depend on the actual cluster (infra ID, node names, worker subnet).
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
export GCP_MASTER_SUBNET="${CLUSTER_INFRA_ID}-master-subnet"

# Worker nodes, sorted: the EVPN data-plane, one Underlay selects all of them.
mapfile -t WORKER_NODES < <(oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
export WORKER_NODES

# Control-plane nodes, sorted: the BGP route reflectors, one per node (each
# needs its own literal static address, so each gets its own Underlay). Their
# k8s node name carries the internal DNS suffix; the GCE instance name is the
# part before the first dot.
mapfile -t MASTER_NODES < <(oc get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
export MASTER_NODES
MASTER_INSTANCE_NAMES=()
for node in "${MASTER_NODES[@]}"; do
    MASTER_INSTANCE_NAMES+=("${node%%.*}")
done
export MASTER_INSTANCE_NAMES

echo "Cluster infra ID   : ${CLUSTER_INFRA_ID}"
echo "Project / region   : ${GCP_PROJECT_ID} / ${GCP_REGION}"
echo "Network            : ${GCP_NETWORK}"
echo "Worker/master subnet: ${GCP_WORKER_SUBNET} / ${GCP_MASTER_SUBNET}"
echo "Route reflectors   : ${MASTER_NODES[*]}"
echo "Worker (client) nodes: ${WORKER_NODES[*]}"
