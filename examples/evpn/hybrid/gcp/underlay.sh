#!/bin/bash
#
# Generates the per node Underlay resources of the GCP cluster.
#
# Each worker gets an ipvlan interface in L3 mode on top of br-ex, since GCP
# rejects traffic sourced from MAC addresses other than the one of the VM NIC.
# The tunnel endpoint (VTEP) address is derived by OpenPERouter from
# tunnelEndpoint.cidrs and the node index, and placed on that ipvlan interface
# (tunnelEndpoint.interfaceName) instead of the router loopback: in L3 mode
# ipvlan only delivers incoming traffic to addresses assigned to the child
# interface itself. GCP must route the address to the node, see setup.sh, which
# registers it as an alias IP of the instance.
#
# The two workers peer with each other through their VTEP addresses and both
# peer with the on-prem leaf reached through the HA VPN with eBGP multihop.

set -xe

CURRENT_PATH=$(dirname "$0")
NAMESPACE="openperouter-system"
ON_PREM_TOR_ADDRESS=10.250.1.3
ON_PREM_TOR_ASN=64515
ON_PREM_UNDERLAY_CIDR=10.250.1.0/24
VTEP_CIDR=192.168.11.0/24
NODE_DOMAIN=".c.ocpstrat-1278.internal"

source "${CURRENT_PATH}/vtep.sh"

WORKER_NODES=$(kubectl get nodes --selector='node-role.kubernetes.io/worker' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep worker-c || true)

if [ -z "$WORKER_NODES" ]; then
    echo "ERROR: No worker-c nodes found"
    exit 1
fi

declare -A NODE_TO_IP
for node in $WORKER_NODES; do
    vtep=$(vtep_ip_for_node "$node" "$VTEP_CIDR")
    NODE_TO_IP["${node%$NODE_DOMAIN}"]="$vtep"
    echo "  ✓ Mapped ${node%$NODE_DOMAIN} -> $vtep"
done

SORTED_NODES=($(printf '%s\n' "${!NODE_TO_IP[@]}" | sort))
if [ ${#SORTED_NODES[@]} -ne 2 ]; then
    echo "ERROR: expected 2 worker-c nodes, got ${#SORTED_NODES[@]}"
    exit 1
fi

underlay() {
    local node=$1
    local asn=$2
    local peer_ip=$3
    local peer_asn=$4
    cat <<EOF
---
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: ${node}
  namespace: ${NAMESPACE}
spec:
  asn: ${asn}
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: ${node}${NODE_DOMAIN}
  tunnelEndpoint:
    interfaceName: net1
    cidrs:
    - ${VTEP_CIDR}
  interfaces:
    - type: CNIDevice
      cniDevice:
        type: RawConfig
        interfaceName: net1
        rawConfig:
          cniVersion: "1.0.0"
          name: ipvlan-underlay
          plugins:
            - type: ipvlan
              master: br-ex
              mode: l3
              capabilities:
                ips: true
              ipam:
                type: static
                routes:
                  - dst: ${ON_PREM_UNDERLAY_CIDR}
                  - dst: ${VTEP_CIDR}
  neighbors:
    - asn: ${peer_asn}
      address: ${peer_ip}
    - asn: ${ON_PREM_TOR_ASN}
      address: ${ON_PREM_TOR_ADDRESS}
      properties:
        - type: ebgpMultiHop
          ebgpMultiHop:
            ttl: 10
EOF
}

{
    underlay "${SORTED_NODES[0]}" 65001 "${NODE_TO_IP[${SORTED_NODES[1]}]}" 65002
    underlay "${SORTED_NODES[1]}" 65002 "${NODE_TO_IP[${SORTED_NODES[0]}]}" 65001
} | kubectl apply -f -
