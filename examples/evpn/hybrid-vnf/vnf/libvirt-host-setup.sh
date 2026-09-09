#!/bin/bash
#
# One-time (per boot) host-level fix for running libvirt VMs (vm-router,
# vm-workload) on a laptop that also runs Docker.
#
# Symptom: a libvirt NAT-mode network's VMs (e.g. the default 192.168.122.0/24
# network) have no outbound connectivity at all -- not even ICMP -- despite:
#   - the host itself having working internet access,
#   - routing, rp_filter, and conntrack all looking correct,
#   - firewalld's own zone/policy chains (inet firewalld table) all showing
#     "policy accept" for virbr0 traffic.
#
# Root cause: Docker sets the classic iptables "filter" table's FORWARD chain
# default policy to DROP (a deliberate Docker security measure, applied
# globally, independent of firewalld/nftables' own "inet firewalld" table).
# Since libvirt's virbr0 forwarding isn't explicitly permitted by any of
# Docker's own chains (DOCKER-USER -> DOCKER-FORWARD -> ... -> DOCKER-BRIDGE,
# all scoped to Docker's own bridges), it falls through to that DROP policy.
# This is a well-known Docker/libvirt interaction, not specific to this
# project -- see Docker's own docs on "docker and iptables". Confirmed via
# `nft monitor trace`: the packet passes every firewalld/libvirt/netbird
# chain with "policy accept", then hits `ip filter FORWARD ... policy drop`
# last.
#
# Fix: add explicit ACCEPT rules to DOCKER-USER, the chain Docker reserves
# specifically for user customizations and never overwrites (survives
# `systemctl restart docker`, but NOT a host reboot -- rerun this script
# after every reboot, or wire it into a systemd oneshot unit if this
# environment persists).
#
# Usage:
#   sudo UPLINK_NIC=enp9s0u2u1u2 ./libvirt-host-setup.sh
set -euo pipefail

UPLINK_NIC="${UPLINK_NIC:?set UPLINK_NIC to the hosts real uplink NIC (the one virbr0-sourced traffic egresses through)}"
LIBVIRT_BRIDGE="${LIBVIRT_BRIDGE:-virbr0}"

if [[ "$(id -u)" -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

echo "=== libvirt/Docker forwarding fix ==="
echo "  uplink:          ${UPLINK_NIC}"
echo "  libvirt bridge:  ${LIBVIRT_BRIDGE}"

if ! iptables -C DOCKER-USER -i "${LIBVIRT_BRIDGE}" -o "${UPLINK_NIC}" -j ACCEPT 2>/dev/null; then
    iptables -I DOCKER-USER -i "${LIBVIRT_BRIDGE}" -o "${UPLINK_NIC}" -j ACCEPT
fi
if ! iptables -C DOCKER-USER -i "${UPLINK_NIC}" -o "${LIBVIRT_BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -I DOCKER-USER -i "${UPLINK_NIC}" -o "${LIBVIRT_BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

echo "  ✓ DOCKER-USER updated"
echo ""
iptables -L DOCKER-USER -n -v
