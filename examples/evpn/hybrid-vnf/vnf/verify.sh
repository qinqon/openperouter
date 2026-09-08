#!/bin/bash
#
# Verifies the on-prem OpenPERouter VNF: VPN tunnel, BGP session to the GCP
# route reflector, EVPN routes, and the VXLAN/bridge datapath. Run as root.
set -uo pipefail

log() { echo "== $* =="; }

log "systemd services"
systemctl --no-pager --plain is-active routerpod-pod.service controllerpod-pod.service 2>/dev/null || true

log "pod containers"
podman ps --format '{{.Names}}\t{{.Status}}' | grep -E 'frr|reloader|vpn|controller' || true

log "IPsec security associations (expect ESTABLISHED)"
podman exec vpn swanctl --list-sas 2>/dev/null || echo "vpn container not ready"

log "BGP summary (expect all 3 GCP route reflectors Established, ipv4 unicast + evpn)"
podman exec frr vtysh -c "show bgp summary" 2>/dev/null || echo "frr not ready"

log "EVPN VNI 110"
podman exec frr vtysh -c "show evpn vni 110" 2>/dev/null || true

log "EVPN type-2/type-3 routes"
podman exec frr vtysh -c "show bgp l2vpn evpn" 2>/dev/null | head -40 || true

log "datapath inside the perouter netns"
ip netns exec perouter ip -br addr show 2>/dev/null || echo "perouter netns missing"
ip netns exec perouter bridge fdb show 2>/dev/null | grep -i vni110 | head || true

log "workload bridge br-vlan members"
bridge link show 2>/dev/null | grep br-vlan || echo "br-vlan not found (run vlan-setup.sh)"
