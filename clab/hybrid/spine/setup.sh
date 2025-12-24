#!/bin/bash
#
# Setup script for spine - Route Reflector
# Configures point-to-point /31 subnets to each leaf

# eth1 -> leafkind
ip addr add 10.250.1.0/31 dev eth1 2>/dev/null || true
ip link set eth1 up

# eth2 -> leafgcp
ip addr add 10.250.1.2/31 dev eth2 2>/dev/null || true
ip link set eth2 up

# eth3 -> leafl3test
ip addr add 10.250.1.4/31 dev eth3 2>/dev/null || true
ip link set eth3 up

echo "Spine interfaces configured"
