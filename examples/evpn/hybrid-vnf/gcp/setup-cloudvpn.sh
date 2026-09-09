#!/bin/bash
#
# Sets up a Classic (policy-based) GCP Cloud VPN from the cluster VPC to the
# on-prem laptop running the OpenPERouter VNF, plus the route and firewall
# rules needed for the EVPN underlay to traverse it:
#   - traffic selectors {GCP_VTEP_CIDR,GCP_RR_CIDR} <-> VNF_VTEP_CIDR -- both
#     GCP pools are needed: the VNF's BGP control-plane sessions go to the
#     route reflectors (GCP_RR_CIDR), while the EVPN VXLAN data plane goes
#     directly to the worker VTEPs (GCP_VTEP_CIDR), since route reflection
#     does not change the l2vpn evpn next-hop.
#   - VPC route VNF_VTEP_CIDR -> tunnel
#   - firewall: BGP(179), VXLAN(4789), ICMP from VNF_VTEP_CIDR
#
# All resources are named with the cluster infra ID prefix and created in the
# cluster's own VPC network, since the project is shared with other clusters.
#
# Requires: env.sh sourced (oc + gcloud), SHARED_SECRET and ONPREM_PUBLIC_IP
# set (network.env or environment). Prints the gateway IP to put in network.env
# as GCP_VPN_IP for the on-prem side.
#
# Usage:
#   ./setup-cloudvpn.sh            # create/update (default)
#   ./setup-cloudvpn.sh cleanup    # delete every resource this script made,
#     in dependency order (route -> tunnel -> forwarding rules -> gateway ->
#     address -> the vnf-allow-onprem firewall rule). Works even after the
#     cluster itself is gone (CLUSTER_INFRA_ID=... env.sh skips oc -- see
#     env.sh), so this can run either just before or any time after
#     destroying the cluster; the shared VPC network is not touched either
#     way. Does not need SHARED_SECRET/ONPREM_PUBLIC_IP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"

PROJECT="$GCP_PROJECT_ID"
REGION="$GCP_REGION"
NETWORK="$GCP_NETWORK"
GW="${CLUSTER_INFRA_ID}-vnf-vpn-gw"
TUNNEL="${CLUSTER_INFRA_ID}-vnf-vpn-tunnel"
ROUTE="${CLUSTER_INFRA_ID}-vnf-route-onprem"
FW="${CLUSTER_INFRA_ID}-vnf-allow-onprem"
gc() { gcloud --project="$PROJECT" "$@"; }

if [[ "${1:-}" == "cleanup" || "${1:-}" == "--cleanup" ]]; then
    echo "=== Cleaning up GCP Cloud VPN (${CLUSTER_INFRA_ID}) ==="

    echo "[1/6] route ${ROUTE}"
    if gc compute routes describe "$ROUTE" &>/dev/null; then
        gc compute routes delete "$ROUTE" --quiet
        echo "  ✓ deleted"
    else
        echo "  ✓ not found (already deleted)"
    fi

    echo "[2/6] tunnel ${TUNNEL}"
    if gc compute vpn-tunnels describe "$TUNNEL" --region="$REGION" &>/dev/null; then
        gc compute vpn-tunnels delete "$TUNNEL" --region="$REGION" --quiet
        echo "  ✓ deleted"
    else
        echo "  ✓ not found (already deleted)"
    fi

    echo "[3/6] forwarding rules"
    for proto in esp udp500 udp4500; do
        rule="${GW}-${proto}"
        if gc compute forwarding-rules describe "$rule" --region="$REGION" &>/dev/null; then
            gc compute forwarding-rules delete "$rule" --region="$REGION" --quiet
            echo "  ✓ deleted ${rule}"
        else
            echo "  ✓ ${rule} not found (already deleted)"
        fi
    done

    echo "[4/6] gateway ${GW}"
    if gc compute target-vpn-gateways describe "$GW" --region="$REGION" &>/dev/null; then
        gc compute target-vpn-gateways delete "$GW" --region="$REGION" --quiet
        echo "  ✓ deleted"
    else
        echo "  ✓ not found (already deleted)"
    fi

    echo "[5/6] address ${GW}-ip"
    if gc compute addresses describe "${GW}-ip" --region="$REGION" &>/dev/null; then
        gc compute addresses delete "${GW}-ip" --region="$REGION" --quiet
        echo "  ✓ deleted"
    else
        echo "  ✓ not found (already deleted)"
    fi

    echo "[6/6] firewall rule ${FW}"
    if gc compute firewall-rules describe "$FW" &>/dev/null; then
        gc compute firewall-rules delete "$FW" --quiet
        echo "  ✓ deleted"
    else
        echo "  ✓ not found (already deleted)"
    fi

    echo ""
    echo "done. The shared VPC network (${NETWORK}) itself is never touched."
    exit 0
fi

: "${SHARED_SECRET:?set SHARED_SECRET in network.env or the environment}"
: "${ONPREM_PUBLIC_IP:=$(curl -4 -s ifconfig.me)}"

echo "=== GCP Cloud VPN to on-prem VNF ==="
echo "  network:   ${NETWORK}"
echo "  on-prem:   ${ONPREM_PUBLIC_IP}"
echo "  selectors: ${GCP_VTEP_CIDR},${GCP_RR_CIDR} <-> ${VNF_VTEP_CIDR}"

echo "[1/5] VPN gateway + external IP"
if ! gc compute target-vpn-gateways describe "$GW" --region="$REGION" &>/dev/null; then
    gc compute addresses create "${GW}-ip" --region="$REGION"
    gc compute target-vpn-gateways create "$GW" --network="$NETWORK" --region="$REGION"
fi
GCP_VPN_IP="$(gc compute addresses describe "${GW}-ip" --region="$REGION" --format='get(address)')"
for proto in esp udp500 udp4500; do
    rule="${GW}-${proto}"
    if ! gc compute forwarding-rules describe "$rule" --region="$REGION" &>/dev/null; then
        case "$proto" in
            esp)     gc compute forwarding-rules create "$rule" --region="$REGION" --ip-protocol=ESP --address="$GCP_VPN_IP" --target-vpn-gateway="$GW";;
            udp500)  gc compute forwarding-rules create "$rule" --region="$REGION" --ip-protocol=UDP --ports=500 --address="$GCP_VPN_IP" --target-vpn-gateway="$GW";;
            udp4500) gc compute forwarding-rules create "$rule" --region="$REGION" --ip-protocol=UDP --ports=4500 --address="$GCP_VPN_IP" --target-vpn-gateway="$GW";;
        esac
    fi
done
echo "  gateway IP: ${GCP_VPN_IP}"

echo "[2/5] VPN tunnel (recreated to keep selectors in sync)"
if gc compute vpn-tunnels describe "$TUNNEL" --region="$REGION" &>/dev/null; then
    gc compute vpn-tunnels delete "$TUNNEL" --region="$REGION" --quiet
fi
gc compute vpn-tunnels create "$TUNNEL" \
    --region="$REGION" \
    --peer-address="$ONPREM_PUBLIC_IP" \
    --shared-secret="$SHARED_SECRET" \
    --ike-version=2 \
    --target-vpn-gateway="$GW" \
    --local-traffic-selector="${GCP_VTEP_CIDR},${GCP_RR_CIDR}" \
    --remote-traffic-selector="$VNF_VTEP_CIDR"

echo "[3/5] route ${VNF_VTEP_CIDR} -> tunnel"
if ! gc compute routes describe "$ROUTE" &>/dev/null; then
    gc compute routes create "$ROUTE" \
        --network="$NETWORK" \
        --destination-range="$VNF_VTEP_CIDR" \
        --next-hop-vpn-tunnel="$TUNNEL" \
        --next-hop-vpn-tunnel-region="$REGION" \
        --priority=100
fi

echo "[4/5] firewall from ${VNF_VTEP_CIDR} (BGP/VXLAN/ICMP)"
if ! gc compute firewall-rules describe "$FW" &>/dev/null; then
    gc compute firewall-rules create "$FW" \
        --network="$NETWORK" \
        --allow=tcp:179,udp:4789,icmp \
        --source-ranges="$VNF_VTEP_CIDR" \
        --description="Allow BGP/VXLAN/ICMP from the on-prem OpenPERouter VNF"
fi

echo "[5/5] done"
echo ""
echo "Set this on the on-prem side (network.env):"
echo "  export GCP_VPN_IP=${GCP_VPN_IP}"
