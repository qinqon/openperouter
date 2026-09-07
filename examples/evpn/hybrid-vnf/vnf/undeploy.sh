#!/bin/bash
#
# Tears down the on-prem OpenPERouter VNF: stops the systemd services, removes
# the quadlets and the "perouter" netns. It does NOT delete the workload VLAN
# bridge (br-vlan) — remove it manually if desired. Run as root.
set -euo pipefail

QUADLET_DIR="/etc/containers/systemd"

log() { echo "[undeploy] $*"; }

if [[ "$(id -u)" -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

log "stopping services"
systemctl stop controllerpod-pod.service 2>/dev/null || true
systemctl stop routerpod-pod.service 2>/dev/null || true

log "removing quadlets"
rm -f "${QUADLET_DIR}"/routerpod.pod "${QUADLET_DIR}"/controllerpod.pod \
      "${QUADLET_DIR}"/frr.container "${QUADLET_DIR}"/reloader.container \
      "${QUADLET_DIR}"/vpn.container "${QUADLET_DIR}"/controller.container \
      "${QUADLET_DIR}"/frr-sockets.volume
systemctl daemon-reload

log "removing perouter netns"
ip netns delete perouter 2>/dev/null || true

log "done. The workload bridge br-vlan and the underlay NIC are left as-is."
log "Remove the bridge manually if desired: ip link delete br-vlan"
