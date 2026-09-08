#!/bin/bash
#
# Generates the OpenPERouter Underlay resources on the GCP OpenShift cluster
# for the VNF VLAN-stretch PoC.
#
# OpenPERouter runs on every node, in exactly two roles, one Underlay each:
#
#   - route-reflectors (control-plane): a pure BGP route reflector (RFC 4456)
#     on each master, no VNIs. Each master still gets its own real address
#     via tunnelEndpoint.interfaceName/GCP_RR_CIDR -- the same
#     derive-per-node-address-on-a-CNIDevice mechanism the workers use for
#     their VTEP, just on a different pool and with no VNI ever placed on it.
#     Reusing it here avoids hand-rolling a second, literal-address scheme
#     for the 3 masters.
#   - workers: the EVPN data-plane. Each worker gets a VTEP derived from
#     GCP_VTEP_CIDR and statically peers every route reflector (their
#     addresses are derived the same way, so they are known once the
#     controller has annotated the masters -- no need to wait for their
#     Underlay to be applied first).
#
# Route reflection changes the BGP next-hop only for ipv4-unicast
# (next-hop-self), not for l2vpn evpn, so EVPN Type-2/3 routes keep the
# originating worker's real VTEP as next-hop: VXLAN data traffic goes directly
# worker-to-worker (or worker-to-VNF), the reflectors carry control-plane
# traffic only.
#
# Every router (RR or worker) gets an ipvlan L3 interface on br-ex, since GCP
# rejects extra source MACs, ruling out macvlan.
#
# Requires: env.sh sourced (oc), OpenPERouter installed on the cluster (the
# node index annotations this script reads come from the controller).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/vtep.sh"

NAMESPACE="openperouter-system"

# The on-prem VNF is a single, non-Kubernetes node running OpenPERouter in
# static/host mode: its tunnelEndpoint has no interfaceName (loopback
# fallback), and static mode always uses the fixed index from node-config.yaml
# (0 in the shipped example) rather than a controller-assigned one -- so its
# address is deterministically the network address of VNF_VTEP_CIDR, exactly
# like index 0 on any other pool.
VNF_VTEP="$(python3 - "$VNF_VTEP_CIDR" <<'PY'
import sys, ipaddress
print(str(ipaddress.ip_network(sys.argv[1]).network_address))
PY
)"

# ipvlan_underlay renders the shared "interfaces" block: an ipvlan-L3 net1 on
# br-ex with the derived tunnel endpoint address injected through the ips
# capability, and routes to every other pool so return traffic finds its way
# back out through it.
ipvlan_underlay() {
    local name=$1
    cat <<EOF
  interfaces:
    - type: CNIDevice
      cniDevice:
        type: RawConfig
        interfaceName: net1
        rawConfig:
          cniVersion: "1.0.0"
          name: ${name}
          plugins:
            - type: ipvlan
              master: br-ex
              mode: l3
              capabilities:
                ips: true
              ipam:
                type: static
                routes:
                  - dst: ${GCP_RR_CIDR}
                  - dst: ${GCP_VTEP_CIDR}
                  - dst: ${VNF_VTEP_CIDR}
EOF
}

route_reflectors() {
    cat <<EOF
---
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: route-reflectors
  namespace: ${NAMESPACE}
spec:
  asn: ${GCP_ASN}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: ""
  tunnelEndpoint:
    interfaceName: net1
    cidrs:
    - ${GCP_RR_CIDR}
$(ipvlan_underlay ipvlan-rr)
  routeReflector:
    clusterID: ${GCP_RR_CLUSTER_ID}
  neighbors:
    - type: Internal
      listenRange: ${GCP_VTEP_CIDR}
      addressFamilies:
        - type: ipv4unicast
          properties:
            - type: routeReflectorClient
        - type: evpn
          properties:
            - type: routeReflectorClient
    # The on-prem VNF, over the Cloud VPN: a different ASN (eBGP), so this
    # sets asn (not type) -- routeReflectorClient is only valid with
    # type: Internal and does not apply to an eBGP peer anyway. addressFamilies
    # must be explicit: the default for an IPv4 neighbor only adds evpn when
    # the *local* underlay has L2VNIs/L3VNIs, which the reflectors never do.
    - asn: ${VNF_ASN}
      address: ${VNF_VTEP}
      properties:
        - type: ebgpMultiHop
          ebgpMultiHop:
            ttl: 10
      addressFamilies:
        - type: ipv4unicast
        - type: evpn
EOF
}

workers() {
    local rr_neighbors=""
    for node in "${MASTER_NODES[@]}"; do
        rr_neighbors+="    - type: Internal"$'\n'"      address: $(vtep_ip_for_node "$node" "$GCP_RR_CIDR")"$'\n'
    done

    cat <<EOF
---
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: workers
  namespace: ${NAMESPACE}
spec:
  asn: ${GCP_ASN}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  tunnelEndpoint:
    interfaceName: net1
    cidrs:
    - ${GCP_VTEP_CIDR}
$(ipvlan_underlay ipvlan-underlay)
  neighbors:
${rr_neighbors%$'\n'}
EOF
}

{
    route_reflectors
    workers
} | oc apply -f -
