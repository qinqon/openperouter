#!/bin/bash
#
# Registers each GCP worker's OpenPERouter VTEP address as an alias IP on its
# instance NIC, so GCP routes the VTEP to the node (GCP only delivers traffic
# to addresses it knows belong to the instance). The VTEP is derived
# deterministically from GCP_VTEP_CIDR and the node index, matching what
# OpenPERouter places on the ipvlan interface.
#
# Scoped strictly to the cluster infra ID because the project is shared.
#
# Requires: env.sh sourced (oc + gcloud authenticated to the project).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/vtep.sh"

for node in "${WORKER_NODES[@]}"; do
    # Safety: only touch instances belonging to this cluster.
    case "$node" in
        "${CLUSTER_INFRA_ID}"-*) ;;
        *) echo "skipping ${node}: not part of ${CLUSTER_INFRA_ID}"; continue;;
    esac

    zone="$(oc get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
    vtep="$(vtep_ip_for_node "$node" "$GCP_VTEP_CIDR")"
    echo "=> ${node} (zone ${zone}) VTEP ${vtep}"

    gcloud compute instances network-interfaces update "$node" \
        --project="$GCP_PROJECT_ID" \
        --zone="$zone" \
        --network-interface=nic0 \
        --aliases="${vtep}/32"
done

echo "done. Verify with:"
echo "  gcloud compute instances describe <node> --zone <zone> --project ${GCP_PROJECT_ID} \\"
echo "    --format='value(networkInterfaces[0].aliasIpRanges[].ipCidrRange)'"
