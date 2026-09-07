#!/bin/bash
#
# Helpers to compute the tunnel endpoint (VTEP) address OpenPERouter derives
# for a node, so that the cloud side can be configured (GCP alias IPs, BGP
# peers) without discovering it at runtime.

# vtep_ip_for_node prints the VTEP address of the node: the address of the
# tunnel endpoint pool at the offset of the node index, as allocated by
# OpenPERouter and recorded in the openpe.io/nodeindex node annotation.
vtep_ip_for_node() {
    local node=$1
    local cidr=$2

    local index
    index=$(node_index "$node")
    if [[ -z "$index" ]]; then
        echo "ERROR: node $node has no openpe.io/nodeindex annotation, is OpenPERouter running?" >&2
        return 1
    fi

    local network=${cidr%/*}
    IFS=. read -r a b c d <<<"$network"
    local base=$(( (a << 24) + (b << 16) + (c << 8) + d + index ))
    echo "$(( (base >> 24) & 255 )).$(( (base >> 16) & 255 )).$(( (base >> 8) & 255 )).$(( base & 255 ))"
}

# node_index prints the node index annotated by OpenPERouter, waiting a bit
# for the controller to annotate a freshly deployed cluster.
node_index() {
    local node=$1
    local index
    for _ in $(seq 1 30); do
        index=$(kubectl get node "$node" -o jsonpath='{.metadata.annotations.openpe\.io/nodeindex}')
        if [[ -n "$index" ]]; then
            echo "$index"
            return 0
        fi
        sleep 2
    done
    return 1
}
