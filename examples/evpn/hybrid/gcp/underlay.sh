#!/bin/bash

set -xe

NAMESPACE="openperouter-system"
ON_PREM_TOR_ADDRESS=10.250.1.3
ON_PREM_TOR_ASN=64515

WORKER_NODES=$(oc get nodes --selector='node-role.kubernetes.io/worker' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep worker-c || true)

if [ -z "$WORKER_NODES" ]; then
    echo "ERROR: No worker-c nodes found"
    exit 1
fi

# Array to store instance info
declare -A NODE_TO_IP

for node in $WORKER_NODES; do

    # Find router pod on this node
    ROUTER_POD=$(oc get pods -n "$NAMESPACE" -l app=router --field-selector spec.nodeName="$node" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$ROUTER_POD" ]; then
        echo "  WARNING: No router pod found on $node"
        continue
    fi

    echo "  Router pod: $ROUTER_POD"

    ROUTER_IP=$(oc get pod "$ROUTER_POD" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null | jq -r '.[] | select(.name == "openperouter-system/underlay") | .ips[0]' 2>/dev/null || true)

    if [ -z "$ROUTER_IP" ]; then
        echo "  WARNING: No underlay IP found on $ROUTER_POD"
        continue
    fi

    # Extract short node name for GCP instance lookup
    SHORT_NODE=$(echo "$node" | sed 's/\.c\.ocpstrat-1278\.internal$//')

    # Store mapping
    NODE_TO_IP["$SHORT_NODE"]="$ROUTER_IP"

    echo "  ✓ Mapped $SHORT_NODE -> $ROUTER_IP"
    echo ""
done

if [ ${#NODE_TO_IP[@]} -eq 0 ]; then
    echo "ERROR: No valid router pod IPs found"
    exit 1
fi

# Generate underlay BGP mesh YAML
echo "==================================="
echo "Generating underlay BGP mesh YAML..."
echo "==================================="

# Sort nodes to ensure consistent ordering
SORTED_NODES=($(printf '%s\n' "${!NODE_TO_IP[@]}" | sort))

# Generate YAML file
kubectl apply -f - <<EOF
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: ${SORTED_NODES[0]}
  namespace: openperouter-system
spec:
  asn: 65001
  evpn:
    vtepInterface: net1
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: ${SORTED_NODES[0]}.c.ocpstrat-1278.internal
  neighbors:
    - asn: 65002
      address: ${NODE_TO_IP[${SORTED_NODES[1]}]}
    - asn: ${ON_PREM_TOR_ASN}
      address: ${ON_PREM_TOR_ADDRESS}
      ebgpMultiHop: true
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: ${SORTED_NODES[1]}
  namespace: openperouter-system
spec:
  asn: 65002
  evpn:
    vtepInterface: net1
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: ${SORTED_NODES[1]}.c.ocpstrat-1278.internal
  neighbors:
    - asn: 65001
      address: ${NODE_TO_IP[${SORTED_NODES[0]}]}
    - asn: ${ON_PREM_TOR_ASN}
      address: ${ON_PREM_TOR_ADDRESS}
      ebgpMultiHop: true
EOF
