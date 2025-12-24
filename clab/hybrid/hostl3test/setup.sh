#!/bin/bash
#
# Setup script for hostl3test
# Connected to leafl3test VRF red interface
# IP: 192.170.2.10/24, Gateway: 192.170.2.1

ip addr add 192.170.2.10/24 dev eth1
ip link set eth1 up

ip route del default 2>/dev/null || true
ip route add default via 192.170.2.1

echo "hostl3test configured: 192.170.2.10/24, gateway 192.170.2.1"
