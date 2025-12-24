#!/bin/bash
# Verification script for hybrid on-prem/GCP EVPN setup
# Usage: ./verify.sh [command]
#
# Commands:
#   all         - Run all verification checks (default)
#   vpn         - Check VPN tunnel status
#   bgp         - Check BGP sessions on all routers
#   evpn        - Check EVPN routes (Type 2, 3, 5)
#   vni         - Check VXLAN VNI status
#   ping-vm     - Ping between on-prem and GCP VMs (L2VNI)
#   ping-l3vni  - Ping between L3VNI test host and GCP (inter-subnet)
#   xfrm        - Check IPsec xfrm policies and errors
#   routes      - Check routing tables
#   help        - Show this help message

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ONPREM_VM="192-170-1-5"
GCP_VM_IP="192.170.1.3"
ONPREM_VM_IP="192.170.1.5"
L3VNI_HOST="clab-kind-hostl3test"
L3VNI_GW_IP="192.170.1.1"

header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

subheader() {
    echo ""
    echo -e "${YELLOW}--- $1 ---${NC}"
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

error() {
    echo -e "${RED}✗ $1${NC}"
}

info() {
    echo -e "  $1"
}

# Get GCP router pod name
get_gcp_router_pod() {
    kubectl --context gcp get pods -n openperouter-system -l app=router -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

#######################
# VPN Verification
#######################
check_vpn() {
    header "VPN Tunnel Status"

    subheader "On-prem leafgcp - strongSwan SA"
    if docker exec clab-kind-leafgcp swanctl --list-sas 2>/dev/null | grep -q "ESTABLISHED"; then
        success "VPN tunnel ESTABLISHED"
        docker exec clab-kind-leafgcp swanctl --list-sas 2>/dev/null
    else
        error "VPN tunnel NOT established"
        docker exec clab-kind-leafgcp swanctl --list-sas 2>/dev/null || true
    fi

    subheader "Traffic Selectors"
    docker exec clab-kind-leafgcp swanctl --list-sas 2>/dev/null | grep -E "local|remote" | tail -2 || true

    subheader "GCP VPN Tunnel Status"
    if command -v gcloud &> /dev/null; then
        TUNNEL_NAME=$(gcloud compute vpn-tunnels list --format="value(name)" 2>/dev/null | head -1)
        if [[ -n "$TUNNEL_NAME" ]]; then
            STATUS=$(gcloud compute vpn-tunnels describe "$TUNNEL_NAME" --format="value(status)" 2>/dev/null || echo "UNKNOWN")
            if [[ "$STATUS" == "ESTABLISHED" ]]; then
                success "GCP VPN tunnel: $STATUS"
            else
                error "GCP VPN tunnel: $STATUS"
            fi
        else
            info "No GCP VPN tunnel found"
        fi
    else
        info "gcloud CLI not available, skipping GCP VPN check"
    fi
}

#######################
# BGP Verification
#######################
check_bgp() {
    header "BGP Sessions"

    subheader "On-prem leafgcp (VPN endpoint)"
    docker exec clab-kind-leafgcp vtysh -c "show bgp summary" 2>/dev/null || error "Failed to get BGP summary from leafgcp"

    subheader "On-prem spine (central eBGP hub)"
    docker exec clab-kind-spine vtysh -c "show bgp summary" 2>/dev/null || error "Failed to get BGP summary from spine"

    subheader "On-prem leafkind (Kind cluster)"
    docker exec clab-kind-leafkind vtysh -c "show bgp summary" 2>/dev/null || error "Failed to get BGP summary from leafkind"

    subheader "On-prem leafl3test (L3VNI)"
    docker exec clab-kind-leafl3test vtysh -c "show bgp summary" 2>/dev/null || error "Failed to get BGP summary from leafl3test"

    subheader "GCP router pod"
    POD=$(get_gcp_router_pod)
    if [[ -n "$POD" ]]; then
        kubectl --context gcp exec -n openperouter-system "$POD" -c frr -- vtysh -c "show bgp summary" 2>/dev/null || error "Failed to get BGP summary from GCP router"
    else
        error "GCP router pod not found"
    fi
}

#######################
# EVPN Verification
#######################
check_evpn() {
    header "EVPN Routes"

    subheader "Type-2 (MAC/IP) routes - leafgcp"
    echo "Looking for VM IPs (192.170.1.x):"
    docker exec clab-kind-leafgcp vtysh -c "show bgp l2vpn evpn route type 2" 2>/dev/null | grep -E "192.170.1\.[0-9]+" -B1 -A2 || info "No Type-2 routes found"

    subheader "Type-3 (VTEP/IMET) routes - leafgcp"
    docker exec clab-kind-leafgcp vtysh -c "show bgp l2vpn evpn route type 3" 2>/dev/null | head -30 || info "No Type-3 routes found"

    subheader "Type-5 (IP prefix) routes - leafgcp"
    docker exec clab-kind-leafgcp vtysh -c "show bgp l2vpn evpn route type 5" 2>/dev/null | head -20 || info "No Type-5 routes found"

    subheader "Type-2 routes - GCP router"
    POD=$(get_gcp_router_pod)
    if [[ -n "$POD" ]]; then
        echo "Looking for VM IPs (192.170.1.x):"
        kubectl --context gcp exec -n openperouter-system "$POD" -c frr -- vtysh -c "show bgp l2vpn evpn route type 2" 2>/dev/null | grep -E "192.170.1\.[0-9]+" -B1 -A2 || info "No Type-2 routes found"
    fi
}

#######################
# VNI Verification
#######################
check_vni() {
    header "VXLAN VNI Status"

    subheader "L2VNI 110 - on-prem (Kind cluster router)"
    # Note: leafgcp is just a VPN endpoint, not a VTEP. Check the Kind cluster router instead.
    POD_PREM=$(kubectl --context prem get pods -n openperouter-system -l app=router -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_PREM" ]]; then
        kubectl --context prem exec -n openperouter-system "$POD_PREM" -c frr -- vtysh -c "show evpn vni 110" 2>/dev/null || info "VNI 110 not found"
    else
        info "On-prem router pod not found, trying leafkind..."
        docker exec clab-kind-leafkind vtysh -c "show evpn vni 110" 2>/dev/null || info "VNI 110 not found on leafkind"
    fi

    subheader "L2VNI 110 MAC table - on-prem"
    if [[ -n "$POD_PREM" ]]; then
        kubectl --context prem exec -n openperouter-system "$POD_PREM" -c frr -- vtysh -c "show evpn mac vni 110" 2>/dev/null || true
    fi

    subheader "L2VNI 110 ARP cache - on-prem"
    if [[ -n "$POD_PREM" ]]; then
        kubectl --context prem exec -n openperouter-system "$POD_PREM" -c frr -- vtysh -c "show evpn arp-cache vni 110" 2>/dev/null || true
    fi

    subheader "L2VNI 110 - GCP router"
    POD=$(get_gcp_router_pod)
    if [[ -n "$POD" ]]; then
        kubectl --context gcp exec -n openperouter-system "$POD" -c frr -- vtysh -c "show evpn vni 110" 2>/dev/null || info "VNI 110 not found on GCP router"
    fi

    subheader "L3VNI 100 (VRF red) - leafl3test"
    docker exec clab-kind-leafl3test vtysh -c "show evpn vni 100" 2>/dev/null || info "VNI 100 not found"
    docker exec clab-kind-leafl3test vtysh -c "show ip route vrf red" 2>/dev/null || true
}

#######################
# VM Ping Test (L2VNI)
#######################
ping_vm() {
    header "VM-to-VM Ping Test (L2VNI 110)"

    info "Testing connectivity from on-prem VM ($ONPREM_VM_IP) to GCP VM ($GCP_VM_IP)"
    info "This uses EVPN Type-2 routes over VXLAN through the VPN tunnel"
    echo ""

    # Check if expect is available
    if ! command -v expect &> /dev/null; then
        error "expect command not found. Install with: sudo dnf install expect"
        return 1
    fi

    # Run ping test via virtctl console
    RESULT=$(expect -c "
set timeout 40
log_user 1
spawn virtctl console --context prem $ONPREM_VM
expect \"Successfully connected\"
sleep 2
send \"\r\"
expect {
    \"login:\" {
        send \"fedora\r\"
        expect \"Password:\"
        send \"fedora\r\"
        expect -re {\\\$ }
    }
    -re {\\\$ } { }
}
send \"ping -c 3 $GCP_VM_IP\r\"
expect -timeout 30 \"packets transmitted\"
send \"exit\r\"
" 2>&1)

    echo "$RESULT" | grep -E "PING|bytes from|packets transmitted|packet loss|time=" || true

    if echo "$RESULT" | grep -q "0% packet loss"; then
        success "VM-to-VM ping successful"
    elif echo "$RESULT" | grep -q "bytes from"; then
        success "VM-to-VM ping working (some packet loss)"
    else
        error "VM-to-VM ping failed"
    fi
}

#######################
# L3VNI Ping Test
#######################
ping_l3vni() {
    header "L3VNI Inter-Subnet Ping Test"

    info "Testing connectivity from leafl3test host (192.170.2.x) to L2VNI gateway ($L3VNI_GW_IP)"
    info "This uses EVPN Type-5 routes for inter-subnet routing via L3VNI 100"
    echo ""

    subheader "Ping from hostl3test to L2VNI gateway (192.170.1.1)"
    if docker exec $L3VNI_HOST ping -c 3 $L3VNI_GW_IP 2>&1; then
        success "L3VNI ping to gateway successful"
    else
        error "L3VNI ping to gateway failed"
    fi

    subheader "Ping from hostl3test to GCP VM ($GCP_VM_IP)"
    if docker exec $L3VNI_HOST ping -c 3 $GCP_VM_IP 2>&1; then
        success "L3VNI ping to GCP VM successful"
    else
        error "L3VNI ping to GCP VM failed"
    fi

    subheader "Ping from hostl3test to on-prem VM ($ONPREM_VM_IP)"
    if docker exec $L3VNI_HOST ping -c 3 $ONPREM_VM_IP 2>&1; then
        success "L3VNI ping to on-prem VM successful"
    else
        error "L3VNI ping to on-prem VM failed"
    fi
}

#######################
# XFRM/IPsec Verification
#######################
check_xfrm() {
    header "IPsec XFRM Status"

    subheader "XFRM Policies (first 40 lines)"
    docker exec clab-kind-leafgcp ip xfrm policy show 2>/dev/null | head -40 || error "Failed to get xfrm policies"

    subheader "XFRM Errors"
    # Filter out zero counters properly (match lines ending with non-zero numbers)
    ERRORS=$(docker exec clab-kind-leafgcp cat /proc/net/xfrm_stat 2>/dev/null | awk -F'[[:space:]]+' '$NF != "0" {print}' || true)
    if [[ -z "$ERRORS" ]]; then
        success "No XFRM errors"
    else
        error "XFRM errors detected:"
        echo "$ERRORS"
        echo ""
        info "Common errors:"
        info "  XfrmInTmplMismatch: Traffic doesn't match IPsec policy (check traffic selectors)"
        info "  XfrmInNoStates: No SA found for incoming packet"
    fi

    subheader "Checking for bypass policies (potential issues)"
    # Look for policies with 'ptype main' that don't have 'tmpl' (no encryption)
    # These are pass-through/bypass policies that could interfere with VPN traffic
    BYPASS=$(docker exec clab-kind-leafgcp bash -c '
        ip xfrm policy show | awk "
        /^src.*dst.*/ {
            if (policy && !has_tmpl && policy !~ /socket/) print policy
            policy=\$0; has_tmpl=0
        }
        /tmpl/ { has_tmpl=1 }
        END { if (policy && !has_tmpl && policy !~ /socket/) print policy }
        " | grep -v "^$" | head -10
    ' 2>/dev/null || true)
    if [[ -n "$BYPASS" ]]; then
        error "Found bypass policies (no encryption template):"
        echo "$BYPASS"
        echo ""
        info "These policies allow traffic to pass without encryption."
        info "Check if 10.250.1.2/31, 172.20.20.0/24, etc. are intentional local bypass."
    else
        success "No problematic bypass policies found"
    fi
}

#######################
# Routes Verification
#######################
check_routes() {
    header "Routing Tables"

    subheader "leafgcp routes"
    docker exec clab-kind-leafgcp ip route show 2>/dev/null || true

    subheader "leafgcp routes (table 220 - policy routing)"
    docker exec clab-kind-leafgcp ip route show table 220 2>/dev/null || info "Table 220 not found"

    subheader "spine routes"
    docker exec clab-kind-spine ip route show 2>/dev/null || true

    subheader "leafl3test VRF red routes"
    docker exec clab-kind-leafl3test ip route show vrf red 2>/dev/null || info "VRF red not found"

    subheader "GCP router routes"
    POD=$(get_gcp_router_pod)
    if [[ -n "$POD" ]]; then
        kubectl --context gcp exec -n openperouter-system "$POD" -c frr -- vtysh -c "show ip route" 2>/dev/null | head -30 || true
    fi
}

#######################
# Help
#######################
show_help() {
    header "Hybrid EVPN Verification Script"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  all         - Run all verification checks (default)"
    echo "  vpn         - Check VPN tunnel status"
    echo "  bgp         - Check BGP sessions on all routers"
    echo "  evpn        - Check EVPN routes (Type 2, 3, 5)"
    echo "  vni         - Check VXLAN VNI status"
    echo "  ping-vm     - Ping between on-prem and GCP VMs (L2VNI)"
    echo "  ping-l3vni  - Ping between L3VNI test host and GCP (inter-subnet)"
    echo "  xfrm        - Check IPsec xfrm policies and errors"
    echo "  routes      - Check routing tables"
    echo "  help        - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Run all checks"
    echo "  $0 vpn          # Check VPN only"
    echo "  $0 ping-vm      # Test VM connectivity"
    echo "  $0 bgp evpn     # Check BGP and EVPN"
}

#######################
# Main
#######################
main() {
    if [[ $# -eq 0 ]]; then
        # Default: run all checks
        check_vpn
        check_bgp
        check_evpn
        check_vni
        check_xfrm
        check_routes
        echo ""
        header "Summary"
        echo "Run './verify.sh ping-vm' to test VM-to-VM connectivity"
        echo "Run './verify.sh ping-l3vni' to test L3VNI inter-subnet routing"
        exit 0
    fi

    for cmd in "$@"; do
        case "$cmd" in
            vpn)
                check_vpn
                ;;
            bgp)
                check_bgp
                ;;
            evpn)
                check_evpn
                ;;
            vni)
                check_vni
                ;;
            ping-vm)
                ping_vm
                ;;
            ping-l3vni)
                ping_l3vni
                ;;
            xfrm)
                check_xfrm
                ;;
            routes)
                check_routes
                ;;
            all)
                check_vpn
                check_bgp
                check_evpn
                check_vni
                check_xfrm
                check_routes
                ;;
            help|--help|-h)
                show_help
                ;;
            *)
                error "Unknown command: $cmd"
                show_help
                exit 1
                ;;
        esac
    done
}

main "$@"
