#!/bin/bash
#
# Generates the OpenPERouter Underlay resources on the GCP OpenShift cluster
# for the VNF VLAN-stretch PoC.
#
# All GCP workers share one ASN. The first worker acts as a BGP route
# reflector (RFC 4456): it accepts dynamic iBGP sessions from the other workers
# over the VTEP range and reflects their ipv4-unicast (VTEP reachability) and
# EVPN routes. It additionally peers the on-prem VNF over the Cloud VPN with an
# eBGP-multihop session, so the VNF learns every GCP VTEP through the single RR
# session and the workers learn the VNF's.
#
# Each router gets an ipvlan L3 interface on br-ex (GCP rejects extra source
# MACs, so macvlan is out) and its VTEP address is placed on that interface via
# tunnelEndpoint.interfaceName.
#
# Requires: env.sh sourced (oc + gcloud), OpenPERouter installed on the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/vtep.sh"

NAMESPACE="openperouter-system"
# The on-prem VNF VTEP the RR peers over the VPN (node index 0 of VNF_VTEP_CIDR,
# i.e. the network address of the pool).
VNF_VTEP="$(python3 - "$VNF_VTEP_CIDR" <<'PY'
import sys,ipaddress
print(str(ipaddress.ip_network(sys.argv[1]).network_address))
PY
)"

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
    - ${GCP_VTEP_CIDR}
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
                  - dst: ${VNF_VTEP_CIDR}
                  - dst: ${GCP_VTEP_CIDR}
${role_specific}
EOF
}

route_reflector() {
    underlay route-reflector <<EOF
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: ${RR_NODE}
  routeReflector:
    clusterID: 192.0.2.1
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
    - asn: ${VNF_ASN}
      address: ${VNF_VTEP}
      properties:
        - type: ebgpMultiHop
          ebgpMultiHop:
            ttl: 10
EOF
}

clients() {
    local values=""
    for node in "${CLIENT_NODES[@]}"; do
        values+="          - ${node}"$'\n'
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
      address: ${GCP_RR_VTEP}
EOF
}

{
    route_reflector
    clients
} | oc apply -f -
