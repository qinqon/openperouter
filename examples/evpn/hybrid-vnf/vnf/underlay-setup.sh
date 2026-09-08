#!/bin/bash
#
# Prepares the underlay uplink interface for the on-prem VNF: a macvlan
# sub-interface in bridge mode on the laptop's real uplink NIC, with its own
# real LAN address.
#
# config/configs/openpe_config.yaml's underlay is a NetworkDevice: whatever
# interface is named there gets MOVED into the "perouter" netns and consumed
# -- it is unusable outside perouter afterwards. A macvlan sub-interface
# avoids sacrificing the laptop's real uplink (which keeps its own address
# and keeps working normally): this only adds a second, disposable interface
# alongside it. It must be given a real address BEFORE deploy.sh runs --
# NetworkDevice never assigns one itself, it only moves the interface and
# restores whatever address(es) it already had (see internal/hostnetwork's
# moveInterfaceFromDefaultNetns). Bridge mode (not private) is required so
# the macvlan interface can reach hosts beyond the local link, like the GCP
# VPN gateway.
#
# Do not run this while VPN/deploy.sh services are already using
# ${MACVLAN_NAME} -- undeploy.sh first, or use a different name.
#
# MTU: deliberately NOT reduced here, unlike the equivalent GCP-side
# interface (gcp/underlay.sh's ipvlan mtu: 1430). On GCP, net1 only carries
# plain VXLAN -- the IPsec tunnel is terminated entirely by the managed
# Cloud VPN gateway, never by the worker VM's own kernel -- so shrinking it
# to account for VPN overhead is safe. On-prem, this SAME macvlan interface
# is both what OpenPERouter reads for its automatic (underlay MTU - 50)
# veth-MTU calculation, AND the actual interface strongSwan's ESP output
# must fit through, since perouter's netns is shared between FRR/VXLAN and
# the VPN sidecar. Shrinking it double-counts the IPsec overhead: it starves
# ESP's own transmission budget (ESP needs the interface's FULL real
# capacity to fit an already-VXLAN-sized packet plus its own ~70 bytes of
# overhead), producing a SMALLER effective MTU than intended, not a
# correctly-sized one (measured concretely as 1316, not the intended 1380,
# when this interface was set to 1430) -- worse than doing nothing.
# Leaving this interface at its real capacity means the on-prem veth/bridge
# chain (br-vlan, pe-e-110, host-e-110) is left at its VXLAN-only-aware
# value (underlay MTU - 50, e.g. 1450) and relies on the kernel's own
# dynamic path-MTU discovery (ICMP "Frag needed", already handled
# transparently by XFRM's own ESP output path) to protect any packet
# actually sized above what the tunnel can carry -- which is exactly what
# was already measured working end-to-end (see the README's MTU gotcha)
# before any interface-level MTU was touched. The trade-off: this relies on
# ICMP working end-to-end for oversized packets, same as any PMTU-discovery
# setup; if that is ever unreliable on a given path, the fix is an
# architectural one (a dedicated, VPN-only netns/interface separate from
# perouter), not a smaller number here.
#
# Usage:
#   UNDERLAY_NIC=enp9s0u2u1u2 UNDERLAY_IP=192.168.1.163/24 \
#     UNDERLAY_GW=192.168.1.1 ./underlay-setup.sh
set -euo pipefail

UNDERLAY_NIC="${UNDERLAY_NIC:?set UNDERLAY_NIC to the laptop real uplink NIC}"
UNDERLAY_IP="${UNDERLAY_IP:?set UNDERLAY_IP to a free address/prefix on that LAN, e.g. 192.168.1.163/24}"
UNDERLAY_GW="${UNDERLAY_GW:?set UNDERLAY_GW to the LAN gateway, e.g. 192.168.1.1}"
MACVLAN_NAME="${MACVLAN_NAME:-macvlan0}"

echo "=== VNF underlay uplink setup ==="
echo "  parent:   ${UNDERLAY_NIC}"
echo "  macvlan:  ${MACVLAN_NAME} (${UNDERLAY_IP})"
echo "  gateway:  ${UNDERLAY_GW}"

# macvlan sub-interface (idempotent).
if ! ip link show "${MACVLAN_NAME}" &>/dev/null; then
    ip link add "${MACVLAN_NAME}" link "${UNDERLAY_NIC}" type macvlan mode bridge
fi
ip addr replace "${UNDERLAY_IP}" dev "${MACVLAN_NAME}"
ip link set "${MACVLAN_NAME}" up

echo "  ✓ ${MACVLAN_NAME} up with ${UNDERLAY_IP}"
echo ""
echo "Set config/configs/openpe_config.yaml's underlay interfaceName to"
echo "\"${MACVLAN_NAME}\" (max 15 chars) if you used a different name, then run"
echo "deploy.sh. The move into perouter preserves this address but not a"
echo "default route -- once deploy.sh has run (perouter exists), add one:"
echo "  ip netns exec perouter ip route add default via ${UNDERLAY_GW} dev ${MACVLAN_NAME}"
ip -br addr show "${MACVLAN_NAME}"
ip -d link show "${MACVLAN_NAME}" | grep -o 'mtu [0-9]*'
