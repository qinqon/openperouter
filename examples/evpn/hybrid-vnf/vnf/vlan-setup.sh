#!/bin/bash
#
# Prepares the workload-side VLAN bridge for the on-prem VNF.
#
# OpenPERouter attaches the EVPN veth of the L2VNI (vni 110) to an EXTERNAL
# Linux bridge named "br-vlan" (see config/configs/openpe_config.yaml). This
# script creates that bridge and plugs a VLAN subinterface of a host NIC into
# it, so tagged workload traffic bridges into the stretched EVPN L2 segment.
#
# Everything here is plain host networking, outside the VNF containers. The
# NIC used here is the WORKLOAD side and is different from the underlay NIC
# consumed by the router (that one is moved into the perouter netns).
#
# Usage:
#   VLAN_NIC=eth2 VLAN_ID=100 ./vlan-setup.sh
set -euo pipefail

VLAN_NIC="${VLAN_NIC:?set VLAN_NIC to the host NIC carrying the workload VLAN}"
VLAN_ID="${VLAN_ID:-100}"
BRIDGE="${BRIDGE:-br-vlan}"
VLAN_IF="${VLAN_NIC}.${VLAN_ID}"

echo "=== VNF workload VLAN setup ==="
echo "  bridge:   ${BRIDGE}"
echo "  nic:      ${VLAN_NIC}"
echo "  vlan:     ${VLAN_ID} (${VLAN_IF})"

# Bridge (idempotent).
if ! ip link show "${BRIDGE}" &>/dev/null; then
    ip link add "${BRIDGE}" type bridge
fi
ip link set "${BRIDGE}" up

# VLAN subinterface (idempotent).
ip link set "${VLAN_NIC}" up
if ! ip link show "${VLAN_IF}" &>/dev/null; then
    ip link add link "${VLAN_NIC}" name "${VLAN_IF}" type vlan id "${VLAN_ID}"
fi
ip link set "${VLAN_IF}" master "${BRIDGE}"
ip link set "${VLAN_IF}" up

echo "  ✓ ${VLAN_IF} enslaved to ${BRIDGE}"
echo ""
echo "The workload on this VLAN reaches the GCP side over the stretched L2VNI."
echo "Give a test host on the VLAN an address in the GCP L2 subnet, e.g.:"
echo "  ip addr add 192.168.100.20/24 dev <host-vlan-iface>"
ip -br link show "${BRIDGE}" || true
bridge link show | grep "${BRIDGE}" || true
