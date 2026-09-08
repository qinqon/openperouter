#!/bin/bash
#
# Helpers to compute the tunnel endpoint address OpenPERouter derives for a
# node, so that the cloud side can be configured (GCP alias IPs, BGP peers)
# without discovering it at runtime. Used for both roles: workers derive
# their VTEP from GCP_VTEP_CIDR, control-plane route reflectors derive their
# own real address the same way from GCP_RR_CIDR (a route reflector has no
# VNIs, but tunnelEndpoint.interfaceName does not require any -- it is a
# generic "derive a per-node address on this CNIDevice" mechanism).

# vtep_ip_for_node prints the tunnel endpoint address of the node: the
# address of the given pool at the offset of the node index, as allocated by
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
# for the controller to annotate a freshly deployed cluster. The annotation
# is set for every node as soon as the controller is running, regardless of
# whether an Underlay selects that node yet.
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
