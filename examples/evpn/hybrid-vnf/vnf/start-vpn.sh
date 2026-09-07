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
set -euo pipefail

: "${GCP_VPN_IP:?GCP_VPN_IP is required}"
: "${ONPREM_PUBLIC_IP:?ONPREM_PUBLIC_IP is required}"
: "${SHARED_SECRET:?SHARED_SECRET is required}"
VNF_VTEP_CIDR="${VNF_VTEP_CIDR:-100.65.0.0/24}"
GCP_VTEP_CIDR="${GCP_VTEP_CIDR:-10.0.200.0/24}"

echo "=== OpenPERouter VNF VPN ==="
echo "  local (on-prem):  ${ONPREM_PUBLIC_IP}"
echo "  remote (GCP):     ${GCP_VPN_IP}"
echo "  local  TS:        ${VNF_VTEP_CIDR}"
echo "  remote TS:        ${GCP_VTEP_CIDR}"

cat > /etc/swanctl/conf.d/gcp.conf <<EOF
connections {
    gcp-vpn {
        version = 2
        local_addrs  = %defaultroute
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
                # Policy-based selectors: only VTEP-to-VTEP traffic is tunneled.
                local_ts  = ${VNF_VTEP_CIDR}
                remote_ts = ${GCP_VTEP_CIDR}
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
        unique = never
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
