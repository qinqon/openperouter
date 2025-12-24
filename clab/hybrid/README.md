# Hybrid Topology - On-Prem + GCP via HA VPN with Dynamic BGP Routing

This topology connects an on-premises kind cluster running openperouter with GCP OpenShift workers via HA VPN and BGP EVPN. Routes are learned dynamically via BGP with Cloud Router - no static routes required.

## Architecture

```
On-Prem (Containerlab)                         GCP
┌────────────────────────────────┐            ┌─────────────────────────────────┐
│  Spine (64612)                 │            │                                 │
│  10.250.1.0/31                 │            │  ┌─────────────┐                │
│  10.250.1.2/31                 │            │  │Cloud Router │                │
│  (Route Reflector)             │            │  │ ASN 64514   │                │
└───┬────────────┬───────────────┘            │  │169.254.0.1  │                │
    │            │                            │  └──────┬──────┘                │
    │            │                            │         │                       │
    │            │                            │    Learns routes                │
    │            │                            │    via BGP:                     │
    │            │                            │    - 10.250.1.0/24              │
┌───┴────┐   ┌───┴──────────────────────┐     │    - 10.250.11.0/24             │
│leafkind│   │       leafgcp            │     │    - 100.65.0.0/24              │
│64512   │   │       64515              │     │    - 100.64.0.0/24              │
│        │   │                          │     │         │                       │
│        │   │  BGP Peers:              │     │         ▼                       │
│        │   │  1. Spine (10.250.1.2)   │     │  ┌─────────────┐                │
│        │   │  2. Cloud Router         │     │  │  HA VPN     │                │
│        │   │     (169.254.0.1)        │◄────┼──│  Gateway    │                │
│        │   │  3. GCP Workers          │     │  └─────────────┘                │
│        │   │     (192.168.11.x)       │     │         │                       │
└───┬────┘   └──────────────────────────┘     │         │                       │
    │                                         │  ┌──────┴──────────────────┐    │
┌───┴─────┐                                   │  │   OpenShift Workers     │    │
│ Switch  │                                   │  │   192.168.11.1-3        │    │
│10.250.11│                                   │  │   ASN 65001-65003       │    │
└─┬─────┬─┘                                   │  └─────────────────────────┘    │
  │     │                                     │                                 │
┌─┴─┐ ┌─┴──┐                                  └─────────────────────────────────┘
│Ctrl│ │Work│
│.3  │ │.4  │
└────┘ └────┘
openperouter
ASN 64514
```

## Key Features

- **Dynamic Routing**: Routes are learned via BGP, not configured statically
- **HA VPN**: Uses GCP HA VPN for better reliability and Cloud Router integration
- **Cloud Router BGP**: leafgcp peers with GCP Cloud Router to advertise on-prem networks
- **EVPN Overlay**: GCP workers peer with leafgcp for EVPN route exchange

## IP Addressing

### Underlay (Spine-Leaf)
- Spine: 10.250.1.0/31, 10.250.1.2/31
- leafkind: 10.250.1.1/31
- leafgcp: 10.250.1.3/31

### Kind Cluster
- leafkind bridge: 10.250.11.1/24
- Control plane: 10.250.11.3/24
- Worker: 10.250.11.4/24

### GCP (via VPN)
- Workers: 192.168.11.1, 192.168.11.2, 192.168.11.3

### Cloud Router BGP (Link-Local)
- Cloud Router: 169.254.0.1
- leafgcp: 169.254.0.2

## BGP Topology

### ASN Assignment
- **64612**: Spine (Route Reflector)
- **64512**: leafkind
- **64514**: Kind cluster openperouter routers AND GCP Cloud Router
- **64515**: leafgcp
- **65001-65003**: GCP workers

### BGP Sessions

| Session | From | To | Purpose |
|---------|------|----|---------|
| Spine ↔ leafkind | 64612 | 64512 | On-prem EVPN |
| Spine ↔ leafgcp | 64612 | 64515 | On-prem EVPN |
| leafgcp ↔ Cloud Router | 64515 | 64514 | VPC route learning |
| leafgcp ↔ GCP workers | 64515 | 65001-65003 | EVPN overlay |

### Routes Advertised by leafgcp to Cloud Router
- `10.250.1.0/24` - Underlay network
- `10.250.11.0/24` - Kind pod network
- `100.65.0.0/24` - Kind VTEPs
- `100.64.0.0/24` - L3VNI test VTEPs
- `192.168.11.0/24` - GCP worker VTEPs (for return traffic)

## VPN Configuration

### GCP Side (HA VPN + Cloud Router)
- **VPN Type**: HA VPN (route-based)
- **Cloud Router ASN**: 64514
- **BGP IP**: 169.254.0.1/30
- **Peer ASN**: 64515 (leafgcp)
- **Peer BGP IP**: 169.254.0.2

### On-Prem (leafgcp)
- **VPN Type**: strongSwan route-based (0.0.0.0/0 traffic selectors)
- **ASN**: 64515
- **BGP IP**: 169.254.0.2/30
- **Cloud Router Peer**: 169.254.0.1

## Deployment

### Prerequisites

1. Set VPN credentials as environment variables:
```bash
# Source the VPN credentials from the GCP sandbox directory
source /home/ellorent/Documents/cnv/sandbox/gcp/.env.vpn
```

Note: VPN credentials are stored outside this repository in `/home/ellorent/Documents/cnv/sandbox/gcp/.env.vpn` for security.

2. Build the FRR+VPN Docker image:
```bash
cd /home/ellorent/Documents/cnv/upstream/openperouter/clab/dockerfile
docker build -f Dockerfile.frr-vpn -t frr-vpn:latest .
```

3. Set up GCP HA VPN and Cloud Router:
```bash
cd /home/ellorent/Documents/cnv/sandbox/gcp/openperouter/examples/evpn/hybrid/gcp
export SHARED_SECRET='your-vpn-shared-secret'
./setup.sh
```

The setup script will:
- Create HA VPN Gateway
- Create Cloud Router with ASN 64514
- Configure BGP peering with leafgcp (169.254.0.2, ASN 64515)
- Output the GCP_VPN_IP needed for leafgcp

### Deploy Topology

Using the Makefile (recommended):
```bash
# Source VPN credentials (includes GCP_VPN_IP from setup.sh output)
source /home/ellorent/Documents/cnv/sandbox/gcp/.env.vpn

# Deploy hybrid topology
cd /home/ellorent/Documents/cnv/upstream/openperouter
make deploy-hybrid
```

Manual deployment:
```bash
# Source VPN credentials
source /home/ellorent/Documents/cnv/sandbox/gcp/.env.vpn

# Deploy
cd /home/ellorent/Documents/cnv/upstream/openperouter/clab
export CLAB_TOPOLOGY="hybrid/kind.clab.yml"
export CLUSTER_NAMES="pe-kind"
./setup.sh pe-kind
```

### Cleanup

To tear down the hybrid topology:
```bash
cd /home/ellorent/Documents/cnv/upstream/openperouter
make undeploy-hybrid
```

To clean up GCP resources:
```bash
cd /home/ellorent/Documents/cnv/sandbox/gcp/openperouter/examples/evpn/hybrid/gcp
./setup.sh cleanup
```

## Verification

### 1. Check VPN Status
```bash
docker exec clab-kind-leafgcp swanctl --list-sas
```

### 2. Check Cloud Router BGP Status
```bash
# From GCP
gcloud compute routers get-status <network>-router --region=<region>

# From leafgcp
docker exec clab-kind-leafgcp vtysh -c "show bgp summary"
docker exec clab-kind-leafgcp vtysh -c "show bgp ipv4 unicast"
```

### 3. Verify Learned Routes in GCP
```bash
# Check Cloud Router learned routes
gcloud compute routers get-status <network>-router --region=<region> \
    --format="yaml(result.bestRoutes)"

# Check VPC routes
gcloud compute routes list --filter="network:<network>"
```

### 4. Check BGP Sessions
```bash
# Spine
docker exec clab-kind-spine vtysh -c "show bgp summary"

# leafgcp
docker exec clab-kind-leafgcp vtysh -c "show bgp summary"

# leafkind
docker exec clab-kind-leafkind vtysh -c "show bgp summary"
```

### 5. Check EVPN Routes
```bash
docker exec clab-kind-leafgcp vtysh -c "show bgp l2vpn evpn"
```

## L2VNI Configuration

To stretch L2VNI between on-prem and GCP:

1. Apply same L2VNI on both clusters:
```yaml
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L2VNI
metadata:
  name: east-west
  namespace: openperouter-system
spec:
  vni: 1000
  vrf: east-west
  vxlanport: 4789
  l2gatewayips:
  - 192.168.100.1/24
```

2. Pods in same VNI can communicate across clouds using VXLAN over VPN

## Troubleshooting

### VPN Not Establishing
```bash
# Check leafgcp logs
docker logs clab-kind-leafgcp

# Check IPsec status
docker exec clab-kind-leafgcp swanctl --list-sas
docker exec clab-kind-leafgcp ipsec status
```

### Cloud Router BGP Session Not Up
```bash
# Check if leafgcp can reach Cloud Router's BGP IP
docker exec clab-kind-leafgcp ping -c 3 169.254.0.1

# Check BGP neighbor state
docker exec clab-kind-leafgcp vtysh -c "show bgp neighbors 169.254.0.1"

# Check Cloud Router status from GCP side
gcloud compute routers get-status <network>-router --region=<region>
```

### Routes Not Being Learned
```bash
# Verify leafgcp is advertising routes
docker exec clab-kind-leafgcp vtysh -c "show bgp ipv4 unicast"

# Check Cloud Router learned routes
gcloud compute routers get-status <network>-router --region=<region> \
    --format="yaml(result.bestRoutesForRouter)"
```

### BGP Sessions Not Establishing with GCP Workers
```bash
# Check reachability
docker exec clab-kind-leafgcp ping -c 3 192.168.11.1  # GCP worker

# Check FRR logs
docker exec clab-kind-leafgcp tail -f /var/log/frr/frr.log
```

### VXLAN Not Working
```bash
# Check if EVPN routes are being exchanged
docker exec clab-kind-leafgcp vtysh -c "show bgp l2vpn evpn"

# Check VTEP IPs
kubectl get pods -n openperouter-system -o wide
```

## Comparison: Classic VPN vs HA VPN

| Feature | Classic VPN (old) | HA VPN (new) |
|---------|-------------------|--------------|
| Routing | Static routes | Dynamic BGP |
| Cloud Router | Not used | Required |
| Route changes | Manual script | Automatic |
| SLA | 99.9% | 99.99% |
| Tunnels | 1 | 2 (for HA) |
| Traffic selectors | Policy-based | Route-based (0.0.0.0/0) |

## Productification Considerations

This PoC uses simplified configurations for ease of testing. For production deployments, implement a **layered security model**.

### Production Security Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: VPN Authentication                                     │
│ - Certificates (not PSK)                                        │
│ - Only authenticated peers can send traffic                     │
│ - This is the TRUST BOUNDARY                                    │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: BGP Route Filtering (Cloud Router)                     │
│ - Prefix lists to accept only expected routes                   │
│ - Reject routes outside allowed ranges                          │
│ - Controls WHAT DESTINATIONS are reachable                      │
├─────────────────────────────────────────────────────────────────┤
│ Layer 3: GCP Firewall (Protocol Filtering)                      │
│ - Specific source ranges (not broad RFC1918)                    │
│ - Specific protocols only (TCP/179, UDP/4789)                   │
│ - Network tags for destination VMs                              │
│ - Controls WHAT PROTOCOLS are allowed to WHICH VMs              │
├─────────────────────────────────────────────────────────────────┤
│ Layer 4: Application Security                                   │
│ - mTLS between services                                         │
│ - Network policies in Kubernetes                                │
│ - Controls WHAT ACTIONS are permitted                           │
└─────────────────────────────────────────────────────────────────┘
```

### VPN Traffic Selectors

The PoC uses **0.0.0.0/0 traffic selectors** (route-based VPN). For production, use explicit selectors:

```bash
# In leafgcp start-vpn.sh, replace:
local_ts = 0.0.0.0/0
remote_ts = 0.0.0.0/0

# With specific networks:
local_ts = 10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24,169.254.0.0/30
remote_ts = 192.168.11.0/24,169.254.0.0/30
```

### GCP Firewall Rules

The PoC uses a single permissive rule. For production:

```bash
# 1. Specific source ranges (not broad RFC1918)
gcloud compute firewall-rules create ${NETWORK}-allow-bgp \
    --network=$NETWORK \
    --allow=tcp:179 \
    --source-ranges=10.250.1.0/24,169.254.0.0/30 \
    --target-tags=vpn-peer \
    --priority=1000

gcloud compute firewall-rules create ${NETWORK}-allow-vxlan \
    --network=$NETWORK \
    --allow=udp:4789 \
    --source-ranges=10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24 \
    --target-tags=vpn-peer \
    --priority=1000

# 2. Default deny for other VPN traffic
gcloud compute firewall-rules create ${NETWORK}-deny-vpn-default \
    --network=$NETWORK \
    --action=DENY \
    --rules=all \
    --source-ranges=10.0.0.0/8,100.64.0.0/10,169.254.0.0/16 \
    --priority=2000

# 3. Tag VMs that should receive VPN traffic
gcloud compute instances add-tags worker-1 --tags=vpn-peer
```

### BGP Route Filtering

Configure Cloud Router to only accept expected prefixes:

```bash
# Use import policies to filter incoming routes
gcloud compute routers update ${NETWORK}-router \
    --region=$REGION \
    --set-advertisement-mode=CUSTOM \
    --set-advertisement-ranges=192.168.11.0/24
```

### High Availability

The current setup uses a single VPN tunnel. For production:

1. Create two VPN tunnels to different HA VPN gateway interfaces
2. Configure BGP on both tunnels for automatic failover
3. Use ECMP for load balancing across tunnels

### Authentication

The PoC uses pre-shared keys (PSK). For production:

1. Use certificate-based authentication
2. If using PSK, rotate regularly and use a secrets manager
3. Never store secrets in environment variables or scripts
