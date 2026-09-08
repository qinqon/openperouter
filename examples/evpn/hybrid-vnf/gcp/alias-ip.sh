#!/bin/bash
#
# Registers each GCP node's OpenPERouter tunnel endpoint address as an alias
# IP on its instance NIC, so GCP routes it to the node (GCP only delivers
# traffic to addresses it knows belong to the instance). Both roles derive
# their address the same way -- workers from GCP_VTEP_CIDR, control-plane
# route reflectors from GCP_RR_CIDR -- via the node index OpenPERouter
# annotates (see vtep.sh), matching underlay.sh exactly.
#
# Scoped strictly to the cluster infra ID because the project is shared.
#
# Requires: env.sh sourced (oc + gcloud authenticated to the project),
# OpenPERouter installed and running (node index annotations must exist).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/vtep.sh"

set_alias() {
    local instance=$1 zone=$2 address=$3
    echo "=> ${instance} (zone ${zone}) address ${address}"
    gcloud compute instances network-interfaces update "$instance" \
        --project="$GCP_PROJECT_ID" \
        --zone="$zone" \
        --network-interface=nic0 \
        --aliases="${address}/32"
}

echo "--- route reflectors (control-plane) ---"
for i in "${!MASTER_NODES[@]}"; do
    node="${MASTER_NODES[$i]}"
    instance="${MASTER_INSTANCE_NAMES[$i]}"
    # Safety: only touch instances belonging to this cluster.
    case "$instance" in
        "${CLUSTER_INFRA_ID}"-*) ;;
        *) echo "skipping ${instance}: not part of ${CLUSTER_INFRA_ID}"; continue;;
    esac
    zone="$(oc get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
    set_alias "$instance" "$zone" "$(vtep_ip_for_node "$node" "$GCP_RR_CIDR")"
done

echo "--- workers (EVPN data plane) ---"
for node in "${WORKER_NODES[@]}"; do
    case "$node" in
        "${CLUSTER_INFRA_ID}"-*) ;;
        *) echo "skipping ${node}: not part of ${CLUSTER_INFRA_ID}"; continue;;
    esac
    zone="$(oc get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
    set_alias "$node" "$zone" "$(vtep_ip_for_node "$node" "$GCP_VTEP_CIDR")"
done

echo "done. Verify with:"
echo "  gcloud compute instances describe <instance> --zone <zone> --project ${GCP_PROJECT_ID} \\"
echo "    --format='value(networkInterfaces[0].aliasIpRanges[].ipCidrRange)'"
