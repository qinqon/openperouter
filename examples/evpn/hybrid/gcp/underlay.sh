#!/bin/bash
#
# Generates the Underlay resources of the GCP cluster.
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
# The GCP nodes share one ASN. The first worker acts as BGP route reflector
# (RFC 4456): it accepts dynamic iBGP sessions from the other workers over the
# VTEP range and reflects their ipv4 unicast (VTEP reachability) and EVPN
# routes, so the workers need no full mesh and adding a node only requires its
# alias IP. All the nodes keep an eBGP multihop session with the on-prem leaf
# reached through the HA VPN, so on-prem connectivity does not depend on the
# reflector.

set -xe

CURRENT_PATH=$(dirname "$0")
NAMESPACE="openperouter-system"
GCP_ASN=65001
ON_PREM_TOR_ADDRESS=10.250.1.3
ON_PREM_TOR_ASN=64515
ON_PREM_UNDERLAY_CIDR=10.250.1.0/24
VTEP_CIDR=192.168.11.0/24
ROUTE_REFLECTOR_CLUSTER_ID=192.0.2.1
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
if [ ${#SORTED_NODES[@]} -lt 2 ]; then
    echo "ERROR: expected at least 2 worker-c nodes, got ${#SORTED_NODES[@]}"
    exit 1
fi
RR_NODE=${SORTED_NODES[0]}
RR_IP=${NODE_TO_IP[$RR_NODE]}
CLIENT_NODES=("${SORTED_NODES[@]:1}")

# underlay prints an Underlay with the common ipvlan L3 CNIDevice and tunnel
# endpoint configuration plus the on-prem leaf neighbor. The role specific
# part (node selector, route reflector and the intra cluster neighbor) is
# read from stdin.
underlay() {
    local name=$1
    local role_specific
    role_specific=$(cat)
    cat <<EOF
---
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  asn: ${GCP_ASN}
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
${role_specific}
    - asn: ${ON_PREM_TOR_ASN}
      address: ${ON_PREM_TOR_ADDRESS}
      properties:
        - type: ebgpMultiHop
          ebgpMultiHop:
            ttl: 10
EOF
}

route_reflector() {
    underlay route-reflector <<EOF
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: ${RR_NODE}${NODE_DOMAIN}
  routeReflector:
    clusterID: ${ROUTE_REFLECTOR_CLUSTER_ID}
  neighbors:
    - type: Internal
      listenRange: ${VTEP_CIDR}
      addressFamilies:
        - type: ipv4unicast
          properties:
            - type: routeReflectorClient
        - type: evpn
          properties:
            - type: routeReflectorClient
EOF
}

clients() {
    local values=""
    for node in "${CLIENT_NODES[@]}"; do
        values+="          - ${node}${NODE_DOMAIN}"$'\n'
    done
    underlay route-reflector-clients <<EOF
  nodeSelector:
    matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
${values%$'\n'}
  neighbors:
    - type: Internal
      address: ${RR_IP}
EOF
}

{
    route_reflector
    clients
} | kubectl apply -f -
