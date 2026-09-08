#!/bin/bash
#
# Simulates a real VLAN-trunked switch and an external host on it entirely in
# software, for testing vlan-setup.sh's actual 802.1Q code path without a
# physical switch. This is a TEST-ONLY tool, not part of the VNF itself.
#
# A plain dummy interface (or any interface with no real link) as
# vlan-setup.sh's VLAN_NIC never receives anything, so its .VLAN_ID
# subinterface never actually strips a tag -- it looks plugged in but proves
# nothing about real 802.1Q handling. This script instead builds a genuine
# VLAN-aware Linux bridge (vlan_filtering) as the "switch", with:
#   - a TRUNK port toward the VNF: carries VLAN_ID tagged, exactly what a
#     real switch uplink to a VNF/router does. Its peer veth is meant to be
#     used as vlan-setup.sh's VLAN_NIC, so the VNF's real .VLAN_ID
#     subinterface does genuine tag stripping on receipt (and tag insertion
#     on send).
#   - an ACCESS port toward a simulated external host: carries VLAN_ID
#     untagged (PVID), exactly like a real end-user device plugged into an
#     access port -- it never runs 8021q itself, same as almost every real
#     device on a VLAN. The host lives in its own network namespace with a
#     plain IP, no VLAN awareness at all.
#
# The switch performs the actual tag add/remove between these two ports,
# using the kernel's real bridge VLAN filtering code -- not a stand-in, not
# a simulation of tagging, the same mechanism a real switch ASIC/software
# switch uses. Verify it directly with `tcpdump -nnei <trunk port>` (shows
# `vlan 100`) vs `tcpdump -nnei <access port>` (plain Ethernet, no tag) while
# pinging across.
#
# Usage:
#   ./sim-switch-setup.sh                       # defaults below
#   VLAN_ID=200 HOST_IP=192.168.100.201/24 ./sim-switch-setup.sh
#
# Then feed the trunk veth into vlan-setup.sh as its real VLAN_NIC:
#   VLAN_NIC=vnf-nic VLAN_ID=100 ./vlan-setup.sh
#
# Teardown: delete the bridge and the two veth pairs (deleting one end of a
# veth pair deletes both), then the netns:
#   ip link del sim-switch; ip link del vnf-nic; ip link del host-nic
#   ip netns del ext-host
set -euo pipefail

VLAN_ID="${VLAN_ID:-100}"
SWITCH_BRIDGE="${SWITCH_BRIDGE:-sim-switch}"
TRUNK_VETH="${TRUNK_VETH:-vnf-nic}"
TRUNK_PORT="${TRUNK_PORT:-sw-trunk-port}"
ACCESS_VETH="${ACCESS_VETH:-host-nic}"
ACCESS_PORT="${ACCESS_PORT:-sw-access-port}"
HOST_NETNS="${HOST_NETNS:-ext-host}"
HOST_IP="${HOST_IP:-192.168.100.200/24}"

echo "=== simulated VLAN switch + external host ==="
echo "  switch:      ${SWITCH_BRIDGE} (vlan_filtering)"
echo "  trunk port:  ${TRUNK_PORT} <-> ${TRUNK_VETH} (tagged, vlan ${VLAN_ID})"
echo "  access port: ${ACCESS_PORT} <-> ${ACCESS_VETH} (untagged/PVID ${VLAN_ID})"
echo "  ext host:    netns ${HOST_NETNS}, ${ACCESS_VETH} = ${HOST_IP}"

# Switch bridge (idempotent).
if ! ip link show "${SWITCH_BRIDGE}" &>/dev/null; then
    ip link add "${SWITCH_BRIDGE}" type bridge vlan_filtering 1
fi
ip link set "${SWITCH_BRIDGE}" up

# Trunk link: TRUNK_VETH is meant to become vlan-setup.sh's VLAN_NIC.
if ! ip link show "${TRUNK_VETH}" &>/dev/null; then
    ip link add "${TRUNK_VETH}" type veth peer name "${TRUNK_PORT}"
fi
ip link set "${TRUNK_PORT}" master "${SWITCH_BRIDGE}"
ip link set "${TRUNK_VETH}" up
ip link set "${TRUNK_PORT}" up
# Pure trunk for VLAN_ID only: drop the default PVID-1-untagged membership
# bridge ports get automatically, then add VLAN_ID as a plain tagged member.
bridge vlan del dev "${TRUNK_PORT}" vid 1 2>/dev/null || true
bridge vlan add dev "${TRUNK_PORT}" vid "${VLAN_ID}"

# Access link: ACCESS_VETH goes into the external host's own netns.
if ! ip link show "${ACCESS_VETH}" &>/dev/null; then
    ip link add "${ACCESS_VETH}" type veth peer name "${ACCESS_PORT}"
fi
ip link set "${ACCESS_PORT}" master "${SWITCH_BRIDGE}"
ip link set "${ACCESS_PORT}" up
bridge vlan del dev "${ACCESS_PORT}" vid 1 2>/dev/null || true
bridge vlan add dev "${ACCESS_PORT}" vid "${VLAN_ID}" pvid untagged

# External host netns (idempotent).
if ! ip netns list | grep -q "^${HOST_NETNS}\b"; then
    ip netns add "${HOST_NETNS}"
fi
if ip link show "${ACCESS_VETH}" &>/dev/null; then
    ip link set "${ACCESS_VETH}" netns "${HOST_NETNS}"
fi
ip netns exec "${HOST_NETNS}" ip link set lo up
ip netns exec "${HOST_NETNS}" ip link set "${ACCESS_VETH}" up
ip netns exec "${HOST_NETNS}" ip addr replace "${HOST_IP}" dev "${ACCESS_VETH}"

echo ""
echo "  ✓ switch configured, external host up"
echo ""
echo "Bridge VLAN table:"
bridge vlan show dev "${TRUNK_PORT}"
bridge vlan show dev "${ACCESS_PORT}"
echo ""
echo "Next: VLAN_NIC=${TRUNK_VETH} VLAN_ID=${VLAN_ID} ./vlan-setup.sh"
echo "Then: ip netns exec ${HOST_NETNS} ping <GCP pod IP>"
