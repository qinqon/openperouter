#!/bin/bash
#
# Brings up the policy-based IPsec tunnel from the on-prem VNF to the GCP Cloud
# VPN gateway. Runs inside the router pod's "perouter" netns so the tunnel, the
# EVPN VTEP and the BGP session to the GCP route reflector share one routing
# table.
#
# Required environment (from /etc/openpe-vnf/vpn.env, see network.env):
#   GCP_VPN_IP        GCP Cloud VPN gateway external IP (remote)
#   ONPREM_PUBLIC_IP  this laptop's public IP (local id)
#   SHARED_SECRET     IPsec pre-shared key
#   VNF_VTEP_CIDR     on-prem VTEP pool advertised into the tunnel (100.65.0.0/24)
#   GCP_VTEP_CIDR     GCP VTEP pool reached over the tunnel (10.0.200.0/24)
#   GCP_RR_CIDR       GCP route-reflector pool reached over the tunnel
#                     (10.0.1.0/24) -- needed for the on-prem BGP sessions;
#                     must match the GCP-side local-traffic-selector set by
#                     setup-cloudvpn.sh, or the CHILD_SA negotiation fails
#                     with TS_UNACCEPTABLE even though IKE_SA succeeds.
set -euo pipefail

: "${GCP_VPN_IP:?GCP_VPN_IP is required}"
: "${ONPREM_PUBLIC_IP:?ONPREM_PUBLIC_IP is required}"
: "${SHARED_SECRET:?SHARED_SECRET is required}"
VNF_VTEP_CIDR="${VNF_VTEP_CIDR:-100.65.0.0/24}"
GCP_VTEP_CIDR="${GCP_VTEP_CIDR:-10.0.200.0/24}"
GCP_RR_CIDR="${GCP_RR_CIDR:-10.0.1.0/24}"

echo "=== OpenPERouter VNF VPN ==="
echo "  local (on-prem):  ${ONPREM_PUBLIC_IP}"
echo "  remote (GCP):     ${GCP_VPN_IP}"
echo "  local  TS:        ${VNF_VTEP_CIDR}"
echo "  remote TS:        ${GCP_VTEP_CIDR},${GCP_RR_CIDR}"

cat > /etc/swanctl/conf.d/gcp.conf <<EOF
connections {
    gcp-vpn {
        version = 2
        # %any: let charon pick the source address via routing to
        # remote_addrs (swanctl.conf/vici equivalent of the legacy
        # ipsec.conf/starter "%defaultroute" keyword, which is NOT valid
        # here and silently fails as "Name does not resolve" since charon
        # tries to resolve it as a literal hostname).
        local_addrs  = %any
        remote_addrs = ${GCP_VPN_IP}
        mobike = yes

        local {
            auth = psk
            id = ${ONPREM_PUBLIC_IP}
        }
        remote {
            auth = psk
            id = ${GCP_VPN_IP}
        }

        children {
            gcp-vpn {
                # Policy-based selectors: only VTEP-to-VTEP traffic is
                # tunneled. Both GCP pools are required: the worker VTEPs
                # (EVPN/VXLAN data plane) and the route reflectors (BGP
                # control plane) -- must match GCP's local-traffic-selector.
                local_ts  = ${VNF_VTEP_CIDR}
                remote_ts = ${GCP_VTEP_CIDR},${GCP_RR_CIDR}
                esp_proposals = aes256gcm16-sha256-modp2048,aes256-sha256-modp2048
                dpd_action = restart
                start_action = start
                close_action = restart
            }
        }

        proposals = aes256-sha256-modp2048,aes256gcm16-prfsha256-modp2048
        dpd_delay = 10s
        dpd_timeout = 30s
        keyingtries = 0
        # replace (not the default "never"): both sides have start_action =
        # start and can each initiate, which races and briefly establishes
        # two independent IKE_SAs to the same peer id after the tunnel has
        # been idle for a while (observed live against GCP Classic VPN).
        # "replace" makes a new IKE_SA from the same peer supersede the old
        # one instead of leaving duplicates installed indefinitely.
        unique = replace
        rekey_time = 36000s
    }
}

secrets {
    ike-gcp {
        id-1 = ${ONPREM_PUBLIC_IP}
        id-2 = ${GCP_VPN_IP}
        secret = "${SHARED_SECRET}"
    }
}
EOF

echo "[vpn] starting charon"
ipsec start --nofork &
CHARON_PID=$!

sleep 3
swanctl --load-all

echo "[vpn] waiting for the tunnel to establish"
for _ in $(seq 1 30); do
    if swanctl --list-sas 2>/dev/null | grep -q ESTABLISHED; then
        echo "[vpn] tunnel established"
        break
    fi
    sleep 1
done

swanctl --list-sas || true

# Keep the container alive tied to charon.
wait "$CHARON_PID"
