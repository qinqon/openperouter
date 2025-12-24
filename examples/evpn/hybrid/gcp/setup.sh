#!/bin/bash -xe

# Source network configuration (subnets, IPs, ASNs)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/network.env" ]]; then
    echo "Loading network configuration from ${SCRIPT_DIR}/network.env"
    source "${SCRIPT_DIR}/network.env"
else
    echo "ERROR: network.env not found at ${SCRIPT_DIR}/network.env"
    exit 1
fi

# Validate required variables from network.env
validate_required_vars() {
    local missing=()
    [[ -z "${GCP_VTEP_CIDR}" ]] && missing+=("GCP_VTEP_CIDR")
    [[ -z "${ONPREM_VTEP_CIDR}" ]] && missing+=("ONPREM_VTEP_CIDR")
    [[ -z "${L3VNI_VTEP_CIDR}" ]] && missing+=("L3VNI_VTEP_CIDR")
    [[ -z "${LEAFGCP_UNDERLAY_CIDR}" ]] && missing+=("LEAFGCP_UNDERLAY_CIDR")
    [[ -z "${CLOUD_ROUTER_BGP_IP}" ]] && missing+=("CLOUD_ROUTER_BGP_IP")
    [[ -z "${LEAFGCP_BGP_IP}" ]] && missing+=("LEAFGCP_BGP_IP")
    [[ -z "${CLOUD_ROUTER_ASN}" ]] && missing+=("CLOUD_ROUTER_ASN")
    [[ -z "${LEAFGCP_ASN}" ]] && missing+=("LEAFGCP_ASN")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required variables in network.env:"
        printf '  - %s\n' "${missing[@]}"
        exit 1
    fi
}
validate_required_vars

# Map to legacy variable name for compatibility
WORKER_SUBNET_CIDR="${GCP_VTEP_CIDR}"

# GCP Cloud VPN Configuration variables
SHARED_SECRET="${SHARED_SECRET:-}"
ONPREM_PUBLIC_IP="${ONPREM_PUBLIC_IP:-$(curl -4 -s ifconfig.me)}"

# Cleanup function - only cleans up resources related to 'ellorent'
cleanup_gcp_resources() {
    FILTER_STRING="ellorent"

    echo "============================================"
    echo "Cleaning up GCP Resources (filter: $FILTER_STRING)"
    echo "============================================"
    echo ""

    # Try to get network info from instances first
    WORKER_SUBNET=$(gcloud compute instances list \
      --filter="name~${FILTER_STRING}" \
      --format="value(networkInterfaces[0].subnetwork.basename())" \
      --limit=1 2>/dev/null || true)

    NETWORK=""
    REGION=""

    if [[ -n "$WORKER_SUBNET" ]]; then
        REGION=$(gcloud compute networks subnets list \
          --filter="name=$WORKER_SUBNET" \
          --format="value(region.basename())" \
          --limit=1 2>/dev/null || true)

        NETWORK=$(gcloud compute networks subnets describe "$WORKER_SUBNET" \
          --region="$REGION" \
          --format="value(network.basename())" 2>/dev/null || true)
    fi

    # If instances are gone, discover network from VPN gateways or networks directly
    if [[ -z "$NETWORK" ]]; then
        echo "No instances found matching '$FILTER_STRING', searching for orphaned networking resources..."

        # Try to find network from HA VPN gateways
        NETWORK=$(gcloud compute vpn-gateways list \
          --filter="name~${FILTER_STRING}" \
          --format="value(network.basename())" \
          --limit=1 2>/dev/null || true)

        if [[ -n "$NETWORK" ]]; then
            REGION=$(gcloud compute vpn-gateways list \
              --filter="name~${FILTER_STRING}" \
              --format="value(region.basename())" \
              --limit=1 2>/dev/null || true)
        fi

        # If still not found, try to find from networks directly
        if [[ -z "$NETWORK" ]]; then
            NETWORK=$(gcloud compute networks list \
              --filter="name~${FILTER_STRING}" \
              --format="value(name)" \
              --limit=1 2>/dev/null || true)
            # Default region for cleanup
            REGION="${REGION:-us-central1}"
        fi
    fi

    if [[ -z "$NETWORK" ]]; then
        echo "No network resources found matching '$FILTER_STRING', nothing to clean up."
        return 0
    fi

    # Only proceed if the network name contains the filter string
    if [[ "$NETWORK" != *"$FILTER_STRING"* ]]; then
        echo "Warning: Network '$NETWORK' does not contain '$FILTER_STRING', skipping VPN/router cleanup"
        echo "Only cleaning up instance alias IPs..."
    else
        echo "Network: $NETWORK"
        echo "Region: $REGION"
        echo ""

        HA_VPN_GATEWAY_NAME="${NETWORK}-ha-vpn"
        VPN_TUNNEL_NAME="${NETWORK}-tunnel-0"
        CLOUD_ROUTER_NAME="${NETWORK}-router"
        EXTERNAL_VPN_GATEWAY_NAME="${NETWORK}-external-vpn"

        # Step 1: Remove BGP peer from Cloud Router
        echo "[1/7] Removing BGP peer..."
        if gcloud compute routers describe $CLOUD_ROUTER_NAME --region=$REGION &>/dev/null; then
            gcloud compute routers remove-bgp-peer $CLOUD_ROUTER_NAME \
                --peer-name=leafgcp \
                --region=$REGION --quiet 2>/dev/null || true
            echo "  ✓ BGP peer removed"
        else
            echo "  ✓ Cloud Router not found (already deleted)"
        fi

        # Step 2: Remove BGP interface from Cloud Router
        echo ""
        echo "[2/7] Removing BGP interface..."
        if gcloud compute routers describe $CLOUD_ROUTER_NAME --region=$REGION &>/dev/null; then
            gcloud compute routers remove-interface $CLOUD_ROUTER_NAME \
                --interface-name=bgp-leafgcp \
                --region=$REGION --quiet 2>/dev/null || true
            echo "  ✓ BGP interface removed"
        fi

        # Step 3: Delete VPN tunnel
        echo ""
        echo "[3/7] Deleting VPN tunnel..."
        if gcloud compute vpn-tunnels describe $VPN_TUNNEL_NAME --region=$REGION &>/dev/null; then
            gcloud compute vpn-tunnels delete $VPN_TUNNEL_NAME --region=$REGION --quiet
            echo "  ✓ VPN tunnel deleted: $VPN_TUNNEL_NAME"
        else
            echo "  ✓ VPN tunnel not found (already deleted)"
        fi

        # Step 4: Delete HA VPN Gateway
        echo ""
        echo "[4/7] Deleting HA VPN gateway..."
        if gcloud compute vpn-gateways describe $HA_VPN_GATEWAY_NAME --region=$REGION &>/dev/null; then
            gcloud compute vpn-gateways delete $HA_VPN_GATEWAY_NAME --region=$REGION --quiet
            echo "  ✓ HA VPN gateway deleted: $HA_VPN_GATEWAY_NAME"
        else
            echo "  ✓ HA VPN gateway not found (already deleted)"
        fi

        # Step 5: Delete External VPN Gateway
        echo ""
        echo "[5/7] Deleting external VPN gateway..."
        if gcloud compute external-vpn-gateways describe $EXTERNAL_VPN_GATEWAY_NAME &>/dev/null; then
            gcloud compute external-vpn-gateways delete $EXTERNAL_VPN_GATEWAY_NAME --quiet
            echo "  ✓ External VPN gateway deleted: $EXTERNAL_VPN_GATEWAY_NAME"
        else
            echo "  ✓ External VPN gateway not found (already deleted)"
        fi

        # Step 6: Skip Cloud Router deletion (managed by OpenShift infra / Jenkins)
        echo ""
        echo "[6/7] Skipping Cloud Router deletion (created by OpenShift infra)"
        echo "  ✓ Cloud Router $CLOUD_ROUTER_NAME preserved"

        # Step 7: Delete firewall rule
        echo ""
        echo "[7/7] Deleting firewall rule..."
        FIREWALL_RULE_NAME="${NETWORK}-allow-vpn-traffic"
        if gcloud compute firewall-rules describe $FIREWALL_RULE_NAME &>/dev/null; then
            gcloud compute firewall-rules delete $FIREWALL_RULE_NAME --quiet
            echo "  ✓ Deleted: $FIREWALL_RULE_NAME"
        else
            echo "  ✓ Not found: $FIREWALL_RULE_NAME"
        fi
    fi

    # Remove alias IPs from instances matching the filter
    echo ""
    echo "Removing alias IPs from instances matching '$FILTER_STRING'..."

    # Get instances matching the filter directly from GCP
    MATCHING_INSTANCES=$(gcloud compute instances list \
        --filter="name~${FILTER_STRING}" \
        --format="csv[no-heading](name,zone.basename())" 2>/dev/null || true)

    if [[ -n "$MATCHING_INSTANCES" ]]; then
        while IFS=',' read -r INSTANCE_NAME ZONE; do
            if [[ -n "$INSTANCE_NAME" && -n "$ZONE" ]]; then
                echo "  Removing alias IP from: $INSTANCE_NAME (zone: $ZONE)"

                # Get current alias IPs
                CURRENT_ALIASES=$(gcloud compute instances describe $INSTANCE_NAME \
                    --zone=$ZONE \
                    --format='value(networkInterfaces[0].aliasIpRanges[].ipCidrRange)' 2>/dev/null || true)

                if [[ -n "$CURRENT_ALIASES" ]]; then
                    # Filter out the openperouter alias IP (192.168.11.x)
                    KEEP_ALIASES=$(echo "$CURRENT_ALIASES" | grep -v "^192\.168\.11\." | tr '\n' ',' | sed 's/,$//' || true)

                    if [[ -n "$KEEP_ALIASES" ]]; then
                        # Update with remaining aliases
                        gcloud compute instances network-interfaces update $INSTANCE_NAME \
                            --zone=$ZONE \
                            --network-interface=nic0 \
                            --aliases="$KEEP_ALIASES"
                    else
                        # Remove all aliases if only openperouter alias existed
                        gcloud compute instances network-interfaces update $INSTANCE_NAME \
                            --zone=$ZONE \
                            --network-interface=nic0 \
                            --aliases=""
                    fi
                    echo "    ✓ Alias IP removed"
                else
                    echo "    ✓ No alias IPs found"
                fi
            fi
        done <<< "$MATCHING_INSTANCES"
    else
        echo "  Warning: No instances found matching '$FILTER_STRING'"
    fi

    echo ""
    echo "============================================"
    echo "Cleanup Complete!"
    echo "============================================"
    echo ""
    echo "Note: The following were NOT removed (manual cleanup if needed):"
    echo "  - Secondary IP range 'openperouter-network' on subnet $WORKER_SUBNET"
    echo "  - Firewall rule: ${NETWORK}-openperouter-network"
    echo "  - VPN config file: /tmp/gcp-vpn-config.env"
    echo ""
}

# Usage function
show_usage() {
    echo "Usage: $0 [cleanup|--cleanup|help|--help]"
    echo ""
    echo "Options:"
    echo "  (no args)        Set up HA VPN + Cloud Router with dynamic BGP routing"
    echo "  cleanup          Remove all GCP resources created by this script"
    echo "  --cleanup        Same as cleanup"
    echo "  help             Show this help message"
    echo "  --help           Same as help"
    echo ""
    echo "Environment variables:"
    echo "  SHARED_SECRET    VPN shared secret (required for setup)"
    echo "  ONPREM_PUBLIC_IP On-prem public IP (default: auto-detected)"
    echo ""
    echo "Examples:"
    echo "  # Setup VPN with dynamic routing"
    echo "  export SHARED_SECRET='your-secret'"
    echo "  ./setup.sh"
    echo ""
    echo "  # Cleanup"
    echo "  ./setup.sh cleanup"
}

# Check for help argument
if [[ "$1" == "help" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Check for cleanup argument
if [[ "$1" == "cleanup" ]] || [[ "$1" == "--cleanup" ]]; then
    cleanup_gcp_resources
    exit $?
fi

WORKER_SUBNET=$(gcloud compute instances list \
  --filter="name~worker" \
  --format="value(networkInterfaces[0].subnetwork.basename())" \
  --limit=1)

if [[ -z "$WORKER_SUBNET" ]]; then
  echo "Error: No worker subnet found"
  exit 1
fi

echo "Worker subnet: $WORKER_SUBNET"

# Get region from the subnet
REGION=$(gcloud compute networks subnets list \
  --filter="name=$WORKER_SUBNET" \
  --format="value(region.basename())" \
  --limit=1)

echo "Region: $REGION"

# Check if secondary range already exists
EXISTING_RANGE=$(gcloud compute networks subnets describe "$WORKER_SUBNET" \
  --region="$REGION" \
  --format="json" | jq -r '.secondaryIpRanges[] | select(.rangeName=="openperouter-network") | .ipCidrRange' 2>/dev/null || true)

if [[ -n "$EXISTING_RANGE" ]]; then
  echo "Secondary range 'openperouter-network' already exists with CIDR: $EXISTING_RANGE"
  if [[ "$EXISTING_RANGE" == "${WORKER_SUBNET_CIDR}" ]]; then
    echo "Range matches desired CIDR ${WORKER_SUBNET_CIDR} - nothing to do"
  else
    echo "Warning: Existing range $EXISTING_RANGE differs from desired ${WORKER_SUBNET_CIDR}"
    echo "Manual intervention required"
    exit 1
  fi
else
  echo "Adding secondary range openperouter-network=${WORKER_SUBNET_CIDR}..."
  gcloud compute networks subnets update "$WORKER_SUBNET" \
    --region="$REGION" \
    --add-secondary-ranges=openperouter-network="${WORKER_SUBNET_CIDR}"
  echo "Secondary range added successfully"
fi

# Verify final state
echo ""
echo "Final subnet configuration:"
gcloud compute networks subnets describe "$WORKER_SUBNET" \
  --region="$REGION" \
  --format="table(name,ipCidrRange,secondaryIpRanges)"

echo ""
echo "=== Configuring Firewall Rules for OpenPERouter Network ==="

# Get the network name from the subnet
NETWORK=$(gcloud compute networks subnets describe "$WORKER_SUBNET" \
  --region="$REGION" \
  --format="value(network.basename())")

echo "Network: $NETWORK"

# Check if firewall rule already exists
FIREWALL_RULE_NAME="${NETWORK}-openperouter-network"
EXISTING_FIREWALL=$(gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
  --format="value(name)" 2>/dev/null || true)

if [[ -n "$EXISTING_FIREWALL" ]]; then
  echo "Firewall rule '$FIREWALL_RULE_NAME' already exists"

  # Verify it has the correct configuration
  EXISTING_SOURCE_RANGES=$(gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
    --format="value(sourceRanges)")

  if [[ "$EXISTING_SOURCE_RANGES" == *"${WORKER_SUBNET_CIDR}"* ]]; then
    echo "Firewall rule already configured for ${WORKER_SUBNET_CIDR}"
  else
    echo "Warning: Firewall rule exists but may have incorrect source ranges"
    echo "Current source ranges: $EXISTING_SOURCE_RANGES"
  fi
else
  echo "Creating firewall rule '$FIREWALL_RULE_NAME'..."
  gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network="$NETWORK" \
    --action=ALLOW \
    --rules=icmp,tcp,udp:4789,esp \
    --source-ranges="${WORKER_SUBNET_CIDR}" \
    --description="Allow traffic from openperouter secondary subnet including VXLAN (UDP 4789)"

  echo "Firewall rule created successfully"
fi

echo ""
echo "Firewall rule status:"
gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
  --format="table(name,network.basename(),sourceRanges,allowed[].map().firewall_rule().list())"

echo ""
echo "=== Cleaning Up Existing Alias IPs from All Instances ==="

# Get all worker nodes
WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

for NODE in $WORKER_NODES; do
  echo ""
  echo "Cleaning node: $NODE"

  # Extract GCE instance name (remove domain suffix)
  INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)

  # Get zone from node labels
  ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

  echo "  Instance: $INSTANCE_NAME"
  echo "  Zone: $ZONE"

  # Get existing alias IPs on the instance
  EXISTING_ALIASES=$(gcloud compute instances describe $INSTANCE_NAME \
    --zone=$ZONE \
    --format='value(networkInterfaces[0].aliasIpRanges[].ipCidrRange)' 2>/dev/null || true)

  if [[ -n "$EXISTING_ALIASES" ]]; then
    echo "  Removing existing alias IPs: $EXISTING_ALIASES"
    gcloud compute instances network-interfaces update $INSTANCE_NAME \
      --zone=$ZONE \
      --network-interface=nic0 \
      --aliases=""
    echo "  ✓ Cleanup complete"
  else
    echo "  No existing alias IPs to clean up"
  fi
done

echo ""
echo "=== Adding Whereabouts IPs as Alias IPs to GCE Instances ==="

for NODE in $WORKER_NODES; do
  echo ""
  echo "Configuring node: $NODE"

  # Extract GCE instance name (remove domain suffix)
  INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)

  # Get zone from node labels
  ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

  echo "  Instance: $INSTANCE_NAME"
  echo "  Zone: $ZONE"

  # Get router pods running on this node
  ROUTER_PODS=$(kubectl get pods -n openperouter-system \
    -l app=router \
    --field-selector spec.nodeName=$NODE \
    -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$ROUTER_PODS" ]]; then
    echo "  No router pods found on this node, skipping..."
    continue
  fi

  # Collect all whereabouts IPs from router pods on this node
  ALIAS_IPS=()
  for POD in $ROUTER_PODS; do
    echo "  Checking pod: $POD"

    # Get IP from network-status annotation (whereabouts-assigned IP)
    WHEREABOUTS_IP=$(kubectl get pod -n openperouter-system $POD \
      -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
      jq -r '.[] | select(.name=="openperouter-system/underlay") | .ips[0]' 2>/dev/null || true)

    if [[ -n "$WHEREABOUTS_IP" ]]; then
      echo "    Found whereabouts IP: $WHEREABOUTS_IP"
      ALIAS_IPS+=("openperouter-network:$WHEREABOUTS_IP/32")
    fi
  done

  if [[ ${#ALIAS_IPS[@]} -eq 0 ]]; then
    echo "  No whereabouts IPs found, skipping..."
    continue
  fi

  # Build the alias list with the whereabouts IPs
  ALIASES_PARAM="--aliases=$(IFS=,; echo "${ALIAS_IPS[*]}")"

  echo "  Adding whereabouts IPs as aliases: ${ALIAS_IPS[@]}"

  # Update the instance with the new alias IPs
  gcloud compute instances network-interfaces update $INSTANCE_NAME \
    --zone=$ZONE \
    --network-interface=nic0 \
    $ALIASES_PARAM
  echo "  ✓ Alias IPs updated successfully"
done

echo ""
echo "=== Alias IP Configuration Complete ==="
echo ""
echo "Verifying final configuration:"
for NODE in $WORKER_NODES; do
  INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)
  ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

  echo ""
  echo "Instance: $INSTANCE_NAME"
  gcloud compute instances describe $INSTANCE_NAME \
    --zone=$ZONE \
    --format='table(networkInterfaces[0].aliasIpRanges[].ipCidrRange)'
done

echo ""
echo "============================================"
echo "GCP HA VPN + Cloud Router Setup"
echo "============================================"
echo ""
echo "This setup uses HA VPN with Cloud Router for dynamic BGP routing."
echo "Routes to on-prem networks will be learned automatically via BGP."
echo ""

# Validate required VPN configuration
if [[ -z "$SHARED_SECRET" ]]; then
  echo "Error: SHARED_SECRET environment variable must be set"
  echo "Export SHARED_SECRET before running this script:"
  echo "  export SHARED_SECRET='your-vpn-shared-secret'"
  exit 1
fi

# Resource names
HA_VPN_GATEWAY_NAME="${NETWORK}-ha-vpn"
EXTERNAL_VPN_GATEWAY_NAME="${NETWORK}-external-vpn"
CLOUD_ROUTER_NAME="${NETWORK}-router"
VPN_TUNNEL_NAME="${NETWORK}-tunnel-0"

echo "Network: $NETWORK"
echo "On-prem Public IP: $ONPREM_PUBLIC_IP"
echo "Cloud Router ASN: $CLOUD_ROUTER_ASN"
echo "Leafgcp ASN: $LEAFGCP_ASN"
echo ""

# Step 1: Create Cloud Router
echo "[1/7] Creating Cloud Router..."
if gcloud compute routers describe $CLOUD_ROUTER_NAME --region=$REGION &>/dev/null; then
    echo "  ✓ Cloud Router $CLOUD_ROUTER_NAME already exists"
else
    gcloud compute routers create $CLOUD_ROUTER_NAME \
        --network=$NETWORK \
        --region=$REGION \
        --asn=$CLOUD_ROUTER_ASN
    echo "  ✓ Cloud Router created with ASN $CLOUD_ROUTER_ASN"
fi

# Step 2: Create HA VPN Gateway
echo ""
echo "[2/7] Creating HA VPN Gateway..."
if gcloud compute vpn-gateways describe $HA_VPN_GATEWAY_NAME --region=$REGION &>/dev/null; then
    echo "  ✓ HA VPN Gateway $HA_VPN_GATEWAY_NAME already exists"
    GCP_VPN_IP=$(gcloud compute vpn-gateways describe $HA_VPN_GATEWAY_NAME \
        --region=$REGION \
        --format="get(vpnInterfaces[0].ipAddress)")
else
    gcloud compute vpn-gateways create $HA_VPN_GATEWAY_NAME \
        --network=$NETWORK \
        --region=$REGION
    GCP_VPN_IP=$(gcloud compute vpn-gateways describe $HA_VPN_GATEWAY_NAME \
        --region=$REGION \
        --format="get(vpnInterfaces[0].ipAddress)")
    echo "  ✓ HA VPN Gateway created with IP: $GCP_VPN_IP"
fi

echo "  Gateway IP: $GCP_VPN_IP"

# Step 3: Create External VPN Gateway (represents leafgcp)
echo ""
echo "[3/7] Creating External VPN Gateway..."
if gcloud compute external-vpn-gateways describe $EXTERNAL_VPN_GATEWAY_NAME &>/dev/null; then
    echo "  ✓ External VPN Gateway $EXTERNAL_VPN_GATEWAY_NAME already exists"
else
    gcloud compute external-vpn-gateways create $EXTERNAL_VPN_GATEWAY_NAME \
        --interfaces 0=$ONPREM_PUBLIC_IP
    echo "  ✓ External VPN Gateway created for peer: $ONPREM_PUBLIC_IP"
fi

# Step 4: Create VPN Tunnel
echo ""
echo "[4/7] Creating VPN Tunnel..."
if gcloud compute vpn-tunnels describe $VPN_TUNNEL_NAME --region=$REGION &>/dev/null; then
    echo "  Deleting existing tunnel to update configuration..."
    gcloud compute vpn-tunnels delete $VPN_TUNNEL_NAME --region=$REGION --quiet
fi

gcloud compute vpn-tunnels create $VPN_TUNNEL_NAME \
    --vpn-gateway=$HA_VPN_GATEWAY_NAME \
    --interface=0 \
    --peer-external-gateway=$EXTERNAL_VPN_GATEWAY_NAME \
    --peer-external-gateway-interface=0 \
    --shared-secret=$SHARED_SECRET \
    --router=$CLOUD_ROUTER_NAME \
    --ike-version=2 \
    --region=$REGION
echo "  ✓ VPN Tunnel created and attached to Cloud Router"

# Step 5: Add BGP Interface to Cloud Router
echo ""
echo "[5/7] Configuring Cloud Router BGP interface..."
# Remove existing interface if it exists
gcloud compute routers remove-interface $CLOUD_ROUTER_NAME \
    --interface-name=bgp-leafgcp \
    --region=$REGION --quiet 2>/dev/null || true

gcloud compute routers add-interface $CLOUD_ROUTER_NAME \
    --interface-name=bgp-leafgcp \
    --ip-address=$CLOUD_ROUTER_BGP_IP \
    --mask-length=30 \
    --vpn-tunnel=$VPN_TUNNEL_NAME \
    --vpn-tunnel-region=$REGION \
    --region=$REGION
echo "  ✓ BGP interface added with IP: $CLOUD_ROUTER_BGP_IP/30"

# Step 6: Add BGP Peer (leafgcp)
echo ""
echo "[6/7] Configuring BGP peer (leafgcp)..."
# Remove existing peer if it exists
gcloud compute routers remove-bgp-peer $CLOUD_ROUTER_NAME \
    --peer-name=leafgcp \
    --region=$REGION --quiet 2>/dev/null || true

gcloud compute routers add-bgp-peer $CLOUD_ROUTER_NAME \
    --peer-name=leafgcp \
    --interface=bgp-leafgcp \
    --peer-ip-address=$LEAFGCP_BGP_IP \
    --peer-asn=$LEAFGCP_ASN \
    --region=$REGION
echo "  ✓ BGP peer added: leafgcp (ASN $LEAFGCP_ASN) at $LEAFGCP_BGP_IP"

# Step 7: Configure firewall rule for VPN traffic
# NOTE: This is a simplified PoC rule. See README Productification section for production security.
echo ""
echo "[7/7] Configuring firewall rule for VPN traffic..."

# Build firewall source ranges from network.env variables
VPN_FIREWALL_RANGES="${FIREWALL_SOURCE_RANGES:-${LEAFGCP_UNDERLAY_CIDR},${ONPREM_VTEP_CIDR},${L3VNI_VTEP_CIDR}}"

FIREWALL_RULE_NAME="${NETWORK}-allow-vpn-traffic"
if ! gcloud compute firewall-rules describe ${FIREWALL_RULE_NAME} &>/dev/null; then
    gcloud compute firewall-rules create ${FIREWALL_RULE_NAME} \
        --network=$NETWORK \
        --allow=tcp:179,udp:4789,icmp \
        --source-ranges="${VPN_FIREWALL_RANGES}" \
        --description="Allow BGP, VXLAN, ICMP from VPN (PoC - see README for production hardening)"
    echo "  ✓ VPN firewall rule created"
else
    echo "  ✓ VPN firewall rule already exists"
fi

# Display Cloud Router status
echo ""
echo "============================================"
echo "Cloud Router Status"
echo "============================================"
gcloud compute routers get-status $CLOUD_ROUTER_NAME --region=$REGION \
    --format="yaml(result.bgpPeerStatus)"

# Display configuration summary
echo ""
echo "============================================"
echo "Configuration Summary"
echo "============================================"
echo ""
echo "HA VPN Gateway:"
echo "  Name: $HA_VPN_GATEWAY_NAME"
echo "  External IP: $GCP_VPN_IP"
echo ""
echo "Cloud Router:"
echo "  Name: $CLOUD_ROUTER_NAME"
echo "  ASN: $CLOUD_ROUTER_ASN"
echo "  BGP IP: $CLOUD_ROUTER_BGP_IP/30"
echo ""
echo "BGP Peer (leafgcp):"
echo "  ASN: $LEAFGCP_ASN"
echo "  BGP IP: $LEAFGCP_BGP_IP"
echo ""
echo "VPN Tunnel: $VPN_TUNNEL_NAME"
echo "  Peer IP: $ONPREM_PUBLIC_IP"
echo ""
echo "Routes will be learned dynamically via BGP:"
echo "  - ${LEAFGCP_UNDERLAY_CIDR}  (leafgcp underlay)"
echo "  - ${ONPREM_VTEP_CIDR}  (on-prem VTEPs)"
echo "  - ${L3VNI_VTEP_CIDR}  (L3VNI test VTEPs)"
echo ""
echo "Firewall Rule:"
echo "  ${NETWORK}-allow-vpn-traffic: tcp:179,udp:4789,icmp from ${VPN_FIREWALL_RANGES}"
echo ""
echo "NOTE: See README Productification section for production security hardening."
echo ""

# Save configuration for containerlab
echo "Saving configuration for containerlab..."
cat > /tmp/gcp-vpn-config.env <<EOF
# GCP HA VPN Configuration for Containerlab
export GCP_VPN_IP=$GCP_VPN_IP
export ONPREM_PUBLIC_IP=$ONPREM_PUBLIC_IP
export SHARED_SECRET=$SHARED_SECRET
export CLOUD_ROUTER_BGP_IP=$CLOUD_ROUTER_BGP_IP
export LEAFGCP_BGP_IP=$LEAFGCP_BGP_IP
export CLOUD_ROUTER_ASN=$CLOUD_ROUTER_ASN
export LEAFGCP_ASN=$LEAFGCP_ASN
EOF

echo "  ✓ Configuration saved to /tmp/gcp-vpn-config.env"
echo ""
echo "============================================"
echo "GCP HA VPN + Cloud Router Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Configure leafgcp container with BGP peer to Cloud Router:"
echo "   - Cloud Router BGP IP: $CLOUD_ROUTER_BGP_IP"
echo "   - Leafgcp BGP IP: $LEAFGCP_BGP_IP"
echo "   - Cloud Router ASN: $CLOUD_ROUTER_ASN"
echo ""
echo "2. Leafgcp should advertise these networks to Cloud Router:"
echo "   - ${LEAFGCP_UNDERLAY_CIDR} (leafgcp underlay)"
echo "   - ${ONPREM_VTEP_CIDR} (on-prem VTEPs)"
echo "   - ${L3VNI_VTEP_CIDR} (L3VNI test VTEPs)"
echo ""
echo "3. Verify BGP session:"
echo "   gcloud compute routers get-status $CLOUD_ROUTER_NAME --region=$REGION"
echo ""
echo "To clean up all resources created by this script:"
echo "  ./setup.sh cleanup"
echo ""
