#!/bin/bash
# Reproducer: stale OVS port entry blocks linux-bridge after VNI deletion
#
# When a VNI uses a pre-existing OVS bridge (autocreate=false),
# RemoveNonConfiguredVNIs deletes the host veth but leaves the OVS
# port entry behind. When a new VNI recreates the veth, OVS reclaims
# it via the stale port, preventing the linux bridge from working.
#
# Prerequisites: a running openperouter kind cluster (make deploy)

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NS="openperouter-system"
NODES=("pe-kind-control-plane" "pe-kind-worker")

pass() { echo -e "\033[32mPASS:\033[0m $*"; }
fail() { echo -e "\033[31mFAIL:\033[0m $*"; }
info() { echo -e "----> $*"; }

cleanup() {
    info "Cleaning up"
    $KUBECTL delete l2vni red110 -n "$NS" --ignore-not-found 2>/dev/null || true
    $KUBECTL delete l3vni red -n "$NS" --ignore-not-found 2>/dev/null || true
    $KUBECTL delete underlay underlay -n "$NS" --ignore-not-found 2>/dev/null || true
    sleep 5
    for node in "${NODES[@]}"; do
        docker exec "$node" ovs-vsctl --if-exists del-br br-ovs-test 2>/dev/null || true
    done
}

#trap cleanup EXIT

# --- Step 0: clean slate ---
cleanup
sleep 2

# --- Step 1: create pre-existing OVS bridge on all nodes ---
info "Creating pre-existing OVS bridge br-ovs-test on kind nodes"
for node in "${NODES[@]}"; do
    docker exec "$node" ovs-vsctl add-br br-ovs-test
done

# --- Step 2: create underlay + L3VNI + L2VNI with ovs-bridge autocreate=false ---
info "Creating underlay + VNIs with ovs-bridge (autocreate=false)"
$KUBECTL apply -f - <<'EOF'
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  asn: 64514
  nics: [toswitch]
  neighbors:
    - asn: 64512
      address: 192.168.11.2
  evpn:
    vtepcidr: 100.65.0.0/24
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L3VNI
metadata:
  name: red
  namespace: openperouter-system
spec:
  vrf: red
  vni: 100
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L2VNI
metadata:
  name: red110
  namespace: openperouter-system
spec:
  vrf: red
  vni: 110
  hostmaster:
    type: ovs-bridge
    ovsBridge:
      name: br-ovs-test
      autoCreate: false
EOF

info "Waiting for reconciliation..."
sleep 15

# --- Step 3: verify OVS has the port ---
info "Checking OVS port attachment"
for node in "${NODES[@]}"; do
    if docker exec "$node" ovs-vsctl show 2>&1 | grep -q "Port host-110"; then
        pass "$node: host-110 attached to OVS bridge br-ovs-test"
    else
        fail "$node: host-110 NOT found in OVS (setup failed)"
        exit 1
    fi
done

# --- Step 4: delete the L2VNI (simulates DeferCleanup between tests) ---
info "Deleting L2VNI and L3VNI (keeping underlay)"
$KUBECTL delete l2vni red110 l3vni red -n "$NS"
sleep 15

exit 1

# --- Step 5: check the stale OVS port ---
info "Checking for stale OVS port after VNI deletion"
STALE=false
for node in "${NODES[@]}"; do
    if docker exec "$node" ovs-vsctl show 2>&1 | grep -q "Port host-110"; then
        fail "$node: STALE OVS port host-110 still present in br-ovs-test"
        docker exec "$node" ovs-vsctl show 2>&1 | grep -A2 "Port host-110" | sed 's/^/     /'
        STALE=true
    else
        pass "$node: OVS port host-110 was cleaned up"
    fi
done

if [ "$STALE" = false ]; then
    echo ""
    pass "No stale ports - bug is fixed!"
    exit 0
fi

# --- Step 6: recreate L2VNI with linux-bridge to show the impact ---
echo ""
info "Recreating VNIs with linux-bridge (autocreate=true) to show the impact"
$KUBECTL apply -f - <<'EOF'
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L3VNI
metadata:
  name: red
  namespace: openperouter-system
spec:
  vrf: red
  vni: 100
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L2VNI
metadata:
  name: red110
  namespace: openperouter-system
spec:
  vrf: red
  vni: 110
  hostmaster:
    type: linux-bridge
    linuxBridge:
      autoCreate: true
EOF

sleep 15

echo ""
info "Checking interface ownership"
for node in "${NODES[@]}"; do
    master=$(docker exec "$node" ip -o link show host-110 2>/dev/null | grep -oP 'master \K\S+' || echo "NONE")
    br_ports=$(docker exec "$node" bridge link show master br-hs-110 2>/dev/null | wc -l)
    echo "  $node:"
    echo "    host-110 master: $master"
    echo "    br-hs-110 ports: $br_ports"
    if [ "$master" = "ovs-system" ]; then
        fail "$node: OVS reclaimed host-110 via stale port - linux bridge br-hs-110 is non-functional"
    elif [ "$br_ports" -gt 0 ]; then
        pass "$node: host-110 correctly attached to linux bridge"
    fi
done

echo ""
fail "Bug reproduced: stale OVS port entries prevent linux-bridge from working"
exit 1
