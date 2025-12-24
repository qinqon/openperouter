#!/bin/bash
set -e

echo "========================================"
echo "Starting leafgcp with HA VPN to GCP"
echo "========================================"

# Start FRR
echo "[1/5] Starting FRR..."
/etc/init.d/frr start
sleep 2

# Enable IP forwarding
echo "[2/5] Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

# Wait for eth1 to be ready
sleep 2

# The route for 192.168.11.0/24 (GCP VTEPs) is learned dynamically via BGP
# from the GCP Cloud Router, so no static route is needed here.

# Configure link-local IP for Cloud Router BGP peering
# This IP is used by FRR to peer with Cloud Router over the VPN tunnel
echo "[3/5] Configuring link-local IP for Cloud Router BGP..."

LEAFGCP_BGP_IP="${LEAFGCP_BGP_IP:-169.254.0.2}"
CLOUD_ROUTER_BGP_IP="${CLOUD_ROUTER_BGP_IP:-169.254.0.1}"

# Create a dummy interface for the link-local BGP IP
# This allows FRR to have a stable source IP for BGP peering with Cloud Router
ip link add dummy0 type dummy 2>/dev/null || true
ip link set dummy0 up
ip addr add ${LEAFGCP_BGP_IP}/32 dev dummy0 2>/dev/null || true

# Add a route for the Cloud Router's link-local IP via the VPN
# This will be refined once the IPsec tunnel is up
# The route goes via eth1 which connects to the internet/VPN endpoint
# IMPORTANT: Use /32 on dummy0, NOT /30. A /30 creates a connected route for
# 169.254.0.0/30 which makes the kernel treat 169.254.0.1 as a link-local
# neighbor on dummy0, bypassing xfrm policy encryption for that destination.
echo "  ✓ Configured ${LEAFGCP_BGP_IP}/32 on dummy0 for BGP peering"
echo "  Cloud Router BGP IP: ${CLOUD_ROUTER_BGP_IP}"

# Configure strongSwan VPN for HA VPN
echo "[4/5] Configuring strongSwan VPN for HA VPN..."
if [[ -z "${GCP_VPN_IP}" ]] || [[ -z "${ONPREM_PUBLIC_IP}" ]] || [[ -z "${SHARED_SECRET}" ]]; then
    echo "ERROR: VPN credentials not set!"
    echo "Required environment variables: GCP_VPN_IP, ONPREM_PUBLIC_IP, SHARED_SECRET"
    exit 1
fi

# HA VPN uses policy-based VPN with specific traffic selectors
# Traffic matching the selectors is encrypted through the tunnel
# NOTE: See README.md "Productification" section for security considerations
cat > /etc/swanctl/conf.d/gcp.conf <<EOF
connections {
    gcp-ha-vpn {
        version = 2
        local_addrs = %defaultroute
        remote_addrs = ${GCP_VPN_IP}

        # Enable MOBIKE for better connection handling
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
            gcp-ha-vpn {
                # Policy-based VPN with specific traffic selectors
                # Use /32 for link-local to avoid bypass policy (same subnet on both sides)
                # Subnets: leafgcp underlay, on-prem VTEPs, L3VNI VTEPs, leafgcp link-local
                local_ts = 10.250.1.0/24,100.65.0.0/24,100.64.0.0/24,169.254.0.2/32
                remote_ts = 192.168.11.0/24,169.254.0.1/32
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

echo "  HA VPN Configuration:"
echo "    Local:  ${ONPREM_PUBLIC_IP}"
echo "    Remote: ${GCP_VPN_IP}"
echo "    Traffic Selectors: policy-based (specific subnets)"
echo "    BGP:    ${LEAFGCP_BGP_IP} <-> ${CLOUD_ROUTER_BGP_IP}"

# Start strongSwan
echo "[5/5] Starting strongSwan..."
ipsec start --nofork &
CHARON_PID=$!

# Wait for charon to be ready
sleep 3

# Load configurations
swanctl --load-all

# Wait for tunnel to establish
echo ""
echo "Waiting for VPN tunnel to establish..."
for i in {1..30}; do
    if swanctl --list-sas 2>/dev/null | grep -q "ESTABLISHED"; then
        echo "  ✓ VPN tunnel established!"
        break
    fi
    sleep 1
done

# strongSwan installs routes in table 220 for remote traffic selectors.
# The route for 192.168.11.0/24 is learned dynamically via BGP from the
# GCP Cloud Router, so no static route is needed here.
# Do NOT add a route for 169.254.0.0/30 - it would create a connected route
# that bypasses xfrm encryption for the Cloud Router link-local address.
echo ""
echo "  ✓ VPN routing configured (remote subnets learned via Cloud Router BGP)"

echo ""
echo "========================================"
echo "leafgcp started successfully!"
echo "========================================"
echo ""
echo "Configuration Summary:"
echo "  VPN Type:     HA VPN (policy-based, specific traffic selectors)"
echo "  VPN Peer:     ${GCP_VPN_IP}"
echo "  BGP Session:  ${LEAFGCP_BGP_IP} (local) <-> ${CLOUD_ROUTER_BGP_IP} (Cloud Router)"
echo ""
echo "Networks advertised to Cloud Router via BGP:"
echo "  - 10.250.1.0/24  (underlay)"
echo "  - 10.250.11.0/24 (kind pods)"
echo "  - 100.65.0.0/24  (kind VTEPs)"
echo "  - 100.64.0.0/24  (L3VNI test VTEPs)"
echo "  - 192.168.11.0/24 (GCP worker VTEPs)"
echo ""
echo "BGP Status:"
vtysh -c "show bgp summary" || true

echo ""
echo "VPN Status:"
swanctl --list-sas || true

echo ""
echo "Interfaces:"
ip -br addr show

echo ""
echo "Routes:"
ip route show

echo ""
echo "Monitoring logs (Ctrl+C to stop)..."
echo "========================================"

# Keep container running and show logs
tail -f /var/log/frr/frr.log 2>/dev/null &
sleep infinity
