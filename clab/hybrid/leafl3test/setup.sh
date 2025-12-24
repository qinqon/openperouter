#!/bin/bash
#
# Setup script for leafl3test - FRR leaf with VRF and EVPN Type-5
#
# This leaf has:
# - VRF "red" with a directly connected subnet (192.170.2.0/24)
# - VXLAN VNI 100 for symmetric IRB (inter-subnet routing)
# - Advertises 192.170.2.0/24 via EVPN Type-5 routes
#
# Traffic to GCP (192.170.1.0/24) is routed via VXLAN VNI 100

sysctl -w net.ipv6.conf.all.keep_addr_on_down=1
sysctl -w net.ipv4.ip_forward=1

# Configure eth1 IP for spine peering (point-to-point /31)
ip addr add 10.250.1.5/31 dev eth1
ip link set eth1 up

# VTEP IP (loopback)
ip addr add 100.64.0.1/32 dev lo

# VRF red
ip link add red type vrf table 1100
ip link set red up

# Host-facing interface in VRF red (directly connected subnet)
ip link set ethred master red
ip addr add 192.170.2.1/24 dev ethred
ip link set ethred up

# VXLAN VNI 100 bridge for symmetric IRB routing
ip link add br100 type bridge
ip link set br100 master red addrgenmode none
ip link set br100 addr aa:bb:cc:00:00:65
ip link add vni100 type vxlan local 100.64.0.1 dstport 4789 id 100 nolearning
ip link set vni100 master br100 addrgenmode none
ip link set vni100 type bridge_slave neigh_suppress on learning off
ip link set vni100 up
ip link set br100 up

echo "leafl3test configured: VRF red with 192.170.2.0/24, VXLAN VNI 100"
