#!/bin/bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$(pwd)/bin/kubeconfig}"

sep() { echo ""; echo "=== $* ==="; }

sep "NODES"
kubectl get nodes -o custom-columns="NAME:.metadata.name,RR:.metadata.labels.openperouter\.io/rr,UNDERLAY-IP:.metadata.annotations.openperouter\.io/underlay-ip"

sep "RR CONTROLLER PODS"
kubectl get pods -n openperouter-system -l app=openperouter-rr-controller -o wide

sep "RAWFRRCONFIGS"
kubectl get rawfrrconfigs -n openperouter-system

sep "ROUTER PODS"
kubectl get pods -n openperouter-system -l app=router -o wide

while IFS=' ' read -r pod node; do
    rr=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.openperouter\.io/rr}' 2>/dev/null)
    role="${rr:+RR}"
    role="${role:-client}"

    sep "BGP L2VPN EVPN SUMMARY — $node ($role)"
    kubectl exec -n openperouter-system "$pod" -c frr -- vtysh -c "show bgp l2vpn evpn summary" 2>/dev/null | \
        grep -E "Neighbor|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"
done < <(kubectl get pods -n openperouter-system -l app=router \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

sep "EVPN ROUTES — best path per RD (RR node)"
RR_POD=$(kubectl get pods -n openperouter-system -l app=router \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | \
    while IFS=' ' read -r pod node; do
        rr=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.openperouter\.io/rr}' 2>/dev/null)
        [[ "$rr" == "true" ]] && echo "$pod" && break
    done)
kubectl exec -n openperouter-system "$RR_POD" -c frr -- vtysh -c "show bgp l2vpn evpn" 2>/dev/null | \
    grep -E "^\*|Network|Route Dist"

sep "EVPN TYPE-3 PATHS ON CLIENT NODE (verify iBGP best path, not ToR)"
CLIENT_POD=$(kubectl get pods -n openperouter-system -l app=router \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | \
    while IFS=' ' read -r pod node; do
        rr=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.openperouter\.io/rr}' 2>/dev/null)
        [[ "$rr" != "true" ]] && echo "$pod" && break
    done)
kubectl exec -n openperouter-system "$CLIENT_POD" -c frr -- \
    vtysh -c "show bgp l2vpn evpn route type multicast" 2>/dev/null | \
    grep -E "^\s+\*|Path$|Network"

sep "EAST/WEST DATA PLANE — VXLAN traffic on underlay bridge"
FIRST_POD=$(kubectl get pod first -o jsonpath='{.metadata.name}' 2>/dev/null || true)
SECOND_POD=$(kubectl get pod second -o jsonpath='{.metadata.name}' 2>/dev/null || true)

if [[ -n "$FIRST_POD" && -n "$SECOND_POD" ]]; then
    SECOND_IP=$(kubectl get pod second \
        -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null | \
        grep -o '"192\.[^"]*"' | tr -d '"' | head -1)
    SECOND_IP="${SECOND_IP:-192.170.1.4}"

    kubectl exec first -- ping -c 5 "$SECOND_IP" > /dev/null 2>&1 &
    PING_PID=$!
    sleep 1

    echo "Capturing VXLAN (UDP 4789) on leafkind-switch — expect direct node-to-node outer IPs:"
    sudo timeout 4 tcpdump -n -i leafkind-switch -c 10 udp port 4789 2>&1 | \
        grep -E "^[0-9]|vxlan|packets captured" || true

    echo ""
    echo "Capturing VXLAN via ToR (192.168.11.2) — expect 0 packets:"
    sudo timeout 2 tcpdump -n -i any -c 5 'host 192.168.11.2 and udp port 4789' 2>&1 | \
        grep "packets captured" || true

    wait $PING_PID 2>/dev/null || true
else
    echo "Workload pods 'first' and 'second' not found — skipping data plane check."
    echo "Deploy them with: kubectl apply -f examples/evpn/layer2/workload.yaml"
fi
