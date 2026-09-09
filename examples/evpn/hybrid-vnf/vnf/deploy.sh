#!/bin/bash
#
# Deploys the on-prem OpenPERouter VNF on the local host using Podman Quadlets
# and systemd, with STATIC configuration only (no Kubernetes, no kubeconfig).
#
# It:
#   1. builds the strongSwan sidecar image (Dockerfile.vpn),
#   2. seeds the static config (node-config.yaml + configs/openpe_*.yaml) and
#      the FRR config into the well-known host paths,
#   3. renders the VPN env from network.env,
#   4. renders the underlay env (UNDERLAY_IFACE/UNDERLAY_GW, both optional --
#      see network.env) for add-underlay-route.sh to pick up,
#   5. installs the quadlets and starts the systemd services.
#
# Run ./add-underlay-route.sh afterwards (once UNDERLAY_IFACE/UNDERLAY_GW are
# set) to add perouter's default route automatically instead of that being a
# manual post-step -- not done by this script itself, since the underlay
# interface move happens asynchronously in the controller's own
# reconciliation loop and can take longer than deploy.sh runs for.
#
# Prerequisites: podman, systemd, a spare underlay NIC (set in
# config/configs/openpe_config.yaml) and the workload VLAN bridge from
# vlan-setup.sh. Run as root.
#
# Usage:
#   ./deploy.sh            # deploy
#   ROUTER_IMAGE=quay.io/openperouter/router:main ./deploy.sh
#   SKIP_VPN_IMAGE_BUILD=1 ./deploy.sh   # reuse an already-loaded
#     localhost/openpe-vnf-vpn:latest instead of rebuilding it. Needed on
#     hosts where rootful `podman build` cannot reach the internet (observed
#     with the netavark rootful network backend on at least one dev
#     machine) even though rootless build and rootful pull/run work fine;
#     build the image rootless instead and load it into root's storage:
#       podman build -t localhost/openpe-vnf-vpn:latest -f Dockerfile.vpn .
#       podman save localhost/openpe-vnf-vpn:latest -o /tmp/vpn.tar
#       sudo podman load -i /tmp/vpn.tar
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_DIR="/etc/containers/systemd"
ROUTER_IMAGE="${ROUTER_IMAGE:-quay.io/openperouter/router:main}"
NETWORK_ENV="${NETWORK_ENV:-${SCRIPT_DIR}/../gcp/network.env}"
SKIP_VPN_IMAGE_BUILD="${SKIP_VPN_IMAGE_BUILD:-0}"

log() { echo "[deploy] $*"; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "must run as root" >&2
        exit 1
    fi
}

require_root

if [[ "${SKIP_VPN_IMAGE_BUILD}" == "1" ]]; then
    log "skipping strongSwan sidecar image build (SKIP_VPN_IMAGE_BUILD=1)"
    podman image exists localhost/openpe-vnf-vpn:latest || {
        echo "SKIP_VPN_IMAGE_BUILD=1 but localhost/openpe-vnf-vpn:latest is not loaded" >&2
        exit 1
    }
else
    log "building strongSwan sidecar image"
    podman build -t localhost/openpe-vnf-vpn:latest -f "${SCRIPT_DIR}/Dockerfile.vpn" "${SCRIPT_DIR}"
fi

log "pulling router image ${ROUTER_IMAGE}"
podman pull "${ROUTER_IMAGE}"
# The quadlets reference quay.io/openperouter/router:main; retag if overridden.
if [[ "${ROUTER_IMAGE}" != "quay.io/openperouter/router:main" ]]; then
    podman tag "${ROUTER_IMAGE}" quay.io/openperouter/router:main
fi

log "seeding static configuration under /var/lib/openperouter"
mkdir -p /var/lib/openperouter/configs /var/lib/openperouter/cni/cache
install -m 0644 "${SCRIPT_DIR}/config/node-config.yaml" /var/lib/openperouter/node-config.yaml
install -m 0644 "${SCRIPT_DIR}"/config/configs/openpe_*.yaml /var/lib/openperouter/configs/

log "seeding FRR config under /etc/perouter/frr"
mkdir -p /etc/perouter/frr
install -m 0644 "${SCRIPT_DIR}"/frrconfig/* /etc/perouter/frr/

log "rendering VPN env into /etc/openpe-vnf/vpn.env"
mkdir -p /etc/openpe-vnf
# shellcheck disable=SC1090
if [[ -f "${NETWORK_ENV}" ]]; then source "${NETWORK_ENV}"; fi
: "${GCP_VPN_IP:?set GCP_VPN_IP (gcp Cloud VPN gateway IP) in network.env or the environment}"
: "${ONPREM_PUBLIC_IP:=$(curl -4 -s ifconfig.me || true)}"
: "${SHARED_SECRET:?set SHARED_SECRET in network.env or the environment}"
cat > /etc/openpe-vnf/vpn.env <<EOF
GCP_VPN_IP=${GCP_VPN_IP}
ONPREM_PUBLIC_IP=${ONPREM_PUBLIC_IP}
SHARED_SECRET=${SHARED_SECRET}
VNF_VTEP_CIDR=${VNF_VTEP_CIDR:-100.65.0.0/24}
GCP_VTEP_CIDR=${GCP_VTEP_CIDR:-10.0.200.0/24}
GCP_RR_CIDR=${GCP_RR_CIDR:-10.0.1.0/24}
EOF
chmod 0600 /etc/openpe-vnf/vpn.env
install -m 0755 "${SCRIPT_DIR}/start-vpn.sh" /etc/openpe-vnf/start-vpn.sh

log "rendering underlay env into /etc/openpe-vnf/underlay.env"
cat > /etc/openpe-vnf/underlay.env <<EOF
UNDERLAY_IFACE=${UNDERLAY_IFACE:-}
UNDERLAY_GW=${UNDERLAY_GW:-}
EOF

log "installing quadlets into ${QUADLET_DIR}"
mkdir -p "${QUADLET_DIR}"
install -m 0644 "${SCRIPT_DIR}"/quadlets/* "${QUADLET_DIR}/"

log "reloading systemd and starting services"
systemctl daemon-reload
systemctl start routerpod-pod.service
systemctl start controllerpod-pod.service

log "done. Check with: ./verify.sh"
