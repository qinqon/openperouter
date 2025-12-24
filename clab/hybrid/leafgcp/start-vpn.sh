#!/bin/bash
set -e

echo "========================================"
echo "Starting leafgcp with VPN to GCP"
echo "========================================"

# Start FRR
echo "[1/4] Starting FRR..."
/etc/init.d/frr start
sleep 2

# Enable IP forwarding
echo "[2/4] Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

# Wait for eth1 to be ready
sleep 2

# Add static route for GCP VTEP network
# This route is needed for:
# 1. BGP to advertise 192.168.11.0/24 to the on-prem network
# 2. IPsec policies to match traffic destined for GCP VTEPs
echo "[2.5/4] Configuring static route for GCP VTEPs..."
ip route add 192.168.11.0/24 dev eth1 || true
echo "  ✓ Added route: 192.168.11.0/24 dev eth1 (advertised via BGP + IPsec trigger)"

# Configure strongSwan VPN
echo "[3/4] Configuring strongSwan VPN..."
if [[ -z "${GCP_VPN_IP}" ]] || [[ -z "${ONPREM_PUBLIC_IP}" ]] || [[ -z "${SHARED_SECRET}" ]]; then
    echo "ERROR: VPN credentials not set!"
    echo "Required environment variables: GCP_VPN_IP, ONPREM_PUBLIC_IP, SHARED_SECRET"
    exit 1
fi

cat > /etc/swanctl/conf.d/gcp.conf <<EOF
connections {
    gcp-tunnel {
        version = 2
        local_addrs = %defaultroute
        remote_addrs = ${GCP_VPN_IP}

        local {
            auth = psk
            id = ${ONPREM_PUBLIC_IP}
        }

        remote {
            auth = psk
            id = ${GCP_VPN_IP}
        }

        children {
            gcp-tunnel {
                local_ts = 10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24
                remote_ts = 192.168.11.0/24
                esp_proposals = aes256-sha256-modp2048
                dpd_action = restart
                start_action = start
                close_action = restart
            }
        }

        proposals = aes256-sha256-modp2048
        dpd_delay = 10s
        dpd_timeout = 30s
        keyingtries = 0
        unique = never
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

echo "  VPN Configuration:"
echo "    Local:  ${ONPREM_PUBLIC_IP}"
echo "    Remote: ${GCP_VPN_IP}"
echo "    Traffic Selectors:"
echo "      Local:  10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24"
echo "      Remote: 192.168.11.0/24"

# Start strongSwan
echo "[4/4] Starting strongSwan..."
ipsec start --nofork &
CHARON_PID=$!

# Wait for charon to be ready
sleep 3

# Load configurations
swanctl --load-all

echo ""
echo "========================================"
echo "leafgcp started successfully!"
echo "========================================"
echo ""
echo "BGP Status:"
vtysh -c "show bgp summary" || true

echo ""
echo "VPN Status:"
swanctl --list-sas || true

echo ""
echo "Monitoring logs (Ctrl+C to stop)..."
echo "========================================"

# Keep container running and show logs
# Use sleep infinity to keep container running even if log files don't exist
tail -f /var/log/frr/frr.log 2>/dev/null &
sleep infinity
