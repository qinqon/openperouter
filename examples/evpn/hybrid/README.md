# EVPN L2/L3 Stretching between On-Premises and GCP OpenShift

This guide demonstrates how to extend Layer 2 and Layer 3 networks between an on-premises containerlab environment and GCP OpenShift cluster using EVPN/VXLAN over IPsec VPN.

## Terminology

**OpenPERouter CRDs** (Kubernetes custom resources):
- **L2VNI**: Creates Layer 2 overlay with VXLAN, bridge interfaces, and EVPN Type-2/3 routes
- **L3VNI**: Creates VRF with VXLAN VNI for symmetric IRB inter-subnet routing

**FRR/Linux concepts** (used by leafl3test):
- **VRF**: Linux VRF for routing table isolation
- **VXLAN VNI**: VXLAN tunnel identifier for overlay traffic
- **EVPN Type-5**: IP prefix routes advertised via BGP for inter-subnet routing

## Features

- **OpenPERouter L2VNI (VNI 110)**: Layer 2 stretching for VM migration between on-prem Kind and GCP (192.170.1.0/24)
- **Inter-subnet routing via EVPN Type-5**: Routing between leafl3test subnet (192.170.2.0/24) and GCP (192.170.1.0/24)

## Architecture

```
┌─────────────────────────────────────────────────────┐      ┌─────────────────────────────────────┐
│           On-Premises (Containerlab)                │      │     GCP OpenShift Cluster           │
│                                                     │      │     (OpenPERouter managed)          │
│  ┌────────────────────────────────────────────┐     │      │                                     │
│  │ Kind Cluster (OpenPERouter)                │     │      │  ┌───────────┐    ┌───────────┐    │
│  │  L2VNI 110: 192.170.1.0/24                 │     │      │  │ worker-1  │    │ worker-2  │    │
│  │  VTEP: 100.65.0.0/24                       │     │      │  │  router   │    │  router   │    │
│  └──────────────┬─────────────────────────────┘     │      │  │192.168.11 │    │192.168.11 │    │
│                 │                                   │      │  │   .10     │    │   .11     │    │
│            ┌────┴────┐                              │      │  └─────┬─────┘    └─────┬─────┘    │
│            │  spine  │                              │      │        └────────┬───────┘          │
│            │ (BGP RR)│                              │ VPN  │            BGP Mesh                │
│            └────┬────┴────────┐                     │Tunnel│                                    │
│                 │             │                     │◄────►│  L2VNI 110: 192.170.1.0/24         │
│            ┌────┴────┐   ┌────┴──────┐              │      │  L3VNI 100: VRF red                │
│            │ leafgcp │   │leafl3test │              │      │  Gateway: 192.170.1.1              │
│            │  (VPN)  │   │  (FRR)    │              │      │                                    │
│            └─────────┘   └────┬──────┘              │      │  VMs: 192.170.1.3, 192.170.1.4     │
│          10.250.1.3      VTEP:100.64.0.1            │      │                                    │
│                               │                     │      └─────────────────────────────────────┘
│                          ┌────┴──────┐              │
│                          │hostl3test │              │
│                          │192.170.2.10│             │
│                          └───────────┘              │
│                                                     │
│  leafl3test (pure FRR, no OpenPERouter):            │
│   - VRF "red" with connected subnet 192.170.2.0/24  │
│   - VXLAN VNI 100 for symmetric IRB                 │
│   - Advertises 192.170.2.0/24 via EVPN Type-5       │
└─────────────────────────────────────────────────────┘

VTEP Subnets:
  - On-prem Kind (OpenPERouter): 100.65.0.0/24
  - On-prem leafl3test (FRR):    100.64.0.0/24
  - GCP (OpenPERouter):          192.168.11.0/24
```

## Prerequisites

- GCP OpenShift cluster deployed
- Containerlab environment with FRR
- Public IP for on-premises VPN endpoint
- OpenPERouter operator installed on both clusters


## 1. OpenPERouter at GCP with a two workers openshift cluster

### Install Operator

Create values.yaml with the image, we are going to run openperouter just on
workers
```yaml
openperouter:
  runOnMaster: false
  logLevel: debug
  multusNetworkAnnotation:
      '[{ "name": "underlay", "namespace": "openperouter-system" }]'
  cri: crio
  image:
    tag: gcp
    repository: quay.io/ellorent/router
    pullPolicy: Always
```

And the ipvlan.yaml
```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "ipvlan-net",
      "type": "ipvlan",
      "master": "br-ex",
      "linkInContainer": false,
      "mode": "l3",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.11.0/24",
        "range_start": "192.168.11.10",
        "range_end": "192.168.11.250",
        "routes": [
          { "dst": "10.250.1.0/24", "via": "net1"}
        ]
      }
    }
```

```bash
git clone -b dnm-gcp https://github.com/qinqon/openperouter.git
make -C openperouter IMG=quay.io/ellorent/router:gcp docker-build docker-push
helm install openperouter ./openperouter/charts/openperouter/ --namespace openperouter-system -f values.yaml --create-namespace

oc apply -f ipvlan.yaml
	
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-controller
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-perouter

kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/l2vnis.openpe.openperouter.github.io
kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/l3vnis.openpe.openperouter.github.io
kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/underlays.openpe.openperouter.github.io
```

## 2. GCP Configuration

### Setup Secondary subnet, whereabouts ip aliases, VPN, Routes, and Firewall

```bash
# Clone the repository
git clone -b gcp https://github.com/yourorg/evpnvirtonopenshift.git
cd evpnvirtonopenshift/scripts

# Set VPN credentials
export SHARED_SECRET="your-secure-psk"

# Run setup script
./setup-gcp.sh
```

After this the network config and secret for VPN is stored at 
`/tmp/gcp-vpn-config.env` so we can source it to have that info.

The script automatically:
- Creates secondary IP range (192.168.11.0/24) on worker subnet
- Assign the whereabouts IPs to the correct GCP instances as ip aliases
- Configures VPN gateway and tunnel with traffic selectors:
  - Local: `192.168.11.0/24`
  - Remote: `10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24`
- Creates routes for on-prem networks:
  - `10.250.1.0/24` - Underlay BGP peering
  - `10.250.11.0/24` - Kind cluster pods
  - `100.65.0.0/24` - Kind cluster VTEPs
  - `100.64.0.0/24` - L3VNI test leaf VTEPs
- Configures firewall rules (BGP, VXLAN from all VTEP subnets, ICMP)
- Assigns alias IPs to worker nodes

### Verify GCP Setup

```bash
# Check VPN tunnel status
gcloud compute vpn-tunnels describe <network>-tunnel-onprem \
  --region=us-central1 --format="value(status)"
# Should show: ESTABLISHED

# Check routes
gcloud compute routes list --filter="name~route-to-onprem"
```

## 3. Configure GCP Underlay, L2VNI and workload

### Configure Underlay Mesh (Per-Node)

Create separate Underlay for each worker with mesh BGP topology:

```bash
evpnvirtonopenshift/cluster-configs/east-west-layer2/gcp/underlay.sh
```

The generated Underlays work like this, one per node:
```yaml
# worker-1 (ASN 65002)
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: worker-1-underlay
  namespace: openperouter-system
spec:
  asn: 65002
  evpn:
    vtepcidr: 192.168.11.0/24
  neighbors:
    - address: 192.168.11.11    # Peer with worker-2
      asn: 65001
    - address: 10.250.1.3       # Peer with on-prem leafgcp
      asn: 64515
      ebgpMultiHop: true
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: worker-1
  routeridcidr: 10.0.0.0/24
```

### Configure L2VNI and L3VNI

```bash
oc apply -f ./evpnvirtonopenshift/cluster-configs/east-west-layer2/01-l2vni.yaml
```

The L2VNI creates the Layer 2 overlay for the 192.170.1.0/24 subnet:
```yaml
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L2VNI
metadata:
  name: layer2
  namespace: openperouter-system
spec:
  hostmaster:
    autocreate: true
    type: linux-bridge
  l2gatewayips: ["192.170.1.1/24"]
  vni: 110
  vrf: red
```

The L3VNI enables symmetric IRB for inter-subnet routing with leafl3test (192.170.2.0/24):
```yaml
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L3VNI
metadata:
  name: l3vni
  namespace: openperouter-system
spec:
  vni: 100
  vrf: red
```

**Note**: Both L2VNI and L3VNI use VRF "red". The L3VNI VNI 100 must match the VXLAN VNI configured on leafl3test for symmetric IRB routing.

### Configure bridge CNI NAD and VMs

```bash
oc apply -f ./evpnvirtonopenshift/cluster-configs/east-west-layer2/02-node-pinned-workloads.yaml
```

## 3. On-Premises OpenPERouter setup with the hybrid clab

### Deploy Containerlab

```bash
source /tmp/gcp-vpn-config.env
make -c ./openperouter docker-build deploy-hybrid
```

## 4. OpenPERouter at On-Prem Kind Cluster

### Configure Underlay and L2VNI

```bash
oc apply -f ./openperouter/examples/evpn/hybrid/cluster-on-prem-openpe.yaml
```

That looks like the following:
```yaml
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: L2VNI
metadata:
  name: layer2
  namespace: openperouter-system
spec:
  hostmaster:
    autocreate: true
    type: linux-bridge
  l2gatewayips: ["192.170.1.1/24"]
  vni: 110
  vrf: red
---
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  asn: 64514
  evpn:
    vtepcidr:  100.65.0.0/24
  nics:
    - toswitch
  neighbors:
    - asn: 64512
      address: 10.250.11.1
```

**Note**: Kind cluster only needs L2VNI since it shares the 192.170.1.0/24 subnet with GCP. The L3VNI for inter-subnet routing with leafl3test (192.170.2.0/24) is configured on GCP and leafl3test (pure FRR).

### Create Workload with bridge CNI

```bash
oc apply -f ./openperouter/examples/evpn/hybrid/cluster-on-prem-workload.yaml
```

## 5. Inter-Subnet Routing Test (leafl3test)

The hybrid topology includes a pure FRR leaf (`leafl3test`) with a test host (`hostl3test`) for testing inter-subnet routing between on-prem and GCP via EVPN Type-5 routes.

**Note**: leafl3test uses native FRR/Linux configuration, NOT OpenPERouter CRDs.

### Topology Components

| Component | IP | Description |
|-----------|-----|-------------|
| leafl3test | 100.64.0.1 (VTEP) | FRR router with VRF red, VXLAN VNI 100 |
| hostl3test | 192.170.2.10/24 | Test host on leafl3test subnet |
| GCP (OpenPERouter) | 192.170.1.0/24 | L2VNI 110 with VMs and gateway |

### Configuration (Auto-applied on Deploy)

Setup scripts run automatically via containerlab `exec`. No manual steps needed.

**leafl3test setup.sh** creates:
- VRF "red" with routing table 1100
- Interface `ethred` in VRF with 192.170.2.1/24
- VXLAN VNI 100 bridge for symmetric IRB

**leafl3test frr.conf** configures:
- BGP peering with spine (ASN 64520 ↔ 64612)
- `redistribute connected` to advertise 192.170.2.0/24 as EVPN Type-5
- `advertise ipv4 unicast` in l2vpn evpn address-family

### Verify Configuration

```bash
# Check BGP peering
docker exec clab-kind-leafl3test vtysh -c "show bgp summary"

# Check EVPN VNIs
docker exec clab-kind-leafl3test vtysh -c "show evpn vni"

# Check VRF red routing table
docker exec clab-kind-leafl3test vtysh -c "show ip route vrf red"
```

### Verify Type-5 Route Advertisement

```bash
# On-prem should advertise 192.170.2.0/24 as Type-5
docker exec clab-kind-spine vtysh -c "show bgp l2vpn evpn route type 5"

# GCP should receive 192.170.2.0/24
kubectl --context gcp exec -n openperouter-system <router-pod> -c frr -- \
  vtysh -c "show bgp l2vpn evpn route type 5"
```

### Test Connectivity

```bash
# Ping GCP gateway from on-prem test host
docker exec clab-kind-hostl3test ping -c 3 192.170.1.1

# Ping GCP VMs (requires IP forwarding enabled on router pods)
docker exec clab-kind-hostl3test ping -c 3 192.170.1.3
docker exec clab-kind-hostl3test ping -c 3 192.170.1.4
```

**Note**: Connectivity to the gateway (192.170.1.1) works because the traffic terminates on the router pod itself. Connectivity to VMs requires the kernel to forward packets between interfaces, which needs `net.ipv4.ip_forward=1`. See [PR #212](https://github.com/openperouter/openperouter/pull/212) for the fix.

### Traffic Flow

```
hostl3test (192.170.2.10)
    → leafl3test ethred (VRF red gateway)
    → VRF red routing lookup
    → VXLAN VNI 100 encap (src VTEP: 100.64.0.1)
    → spine → leafgcp → VPN tunnel
    → GCP worker (dst VTEP: 192.168.11.x)
    → VXLAN VNI 100 decap
    → OpenPERouter VRF red → L2VNI 110 gateway (192.170.1.1)
```

## 6. Verification

### Check VPN Tunnel

```bash
# On-prem
docker exec clab-kind-leafgcp swanctl --list-sas

# GCP
gcloud compute vpn-tunnels describe <network>-tunnel-onprem \
  --region=us-central1 --format="value(status)"
```

### Check BGP Sessions

```bash
# GCP
kubectl exec -n openperouter-system <router-pod> -c frr -- \
  vtysh -c "show bgp summary"

# On-prem
docker exec clab-kind-leafgcp vtysh -c "show bgp summary"
```

### Check EVPN Routes

```bash
# Type-2 (MAC/IP) routes
vtysh -c "show bgp l2vpn evpn route type 2"

# Type-3 (VTEP) routes
vtysh -c "show bgp l2vpn evpn route type 3"
```

### Check VXLAN VNI

```bash
kubectl exec -n openperouter-system <router-pod> -c frr -- \
  vtysh -c "show evpn vni 110"
```

### Test VTEP Connectivity

```bash
# From on-prem to GCP
kubectl exec -n openperouter-system <router-pod> -c frr -- \
  ping -I 100.65.0.0 -c 3 192.168.11.10

# From GCP to on-prem
kubectl exec -n openperouter-system <router-pod> -c frr -- \
  ping -c 3 100.65.0.0
```

### Test VM Connectivity

```bash
# Check learned MACs
vtysh -c "show evpn mac vni 110"

# Check ARP cache
vtysh -c "show evpn arp-cache vni 110"
```

## Key Configuration Points

1. **Traffic Selectors**: VPN must allow underlay and all VTEP subnets:
   - `10.250.1.0/24` - Underlay BGP peering
   - `10.250.11.0/24` - Kind cluster pods
   - `100.65.0.0/24` - Kind cluster VTEPs (OpenPERouter)
   - `100.64.0.0/24` - leafl3test VTEPs (FRR)
2. **GCP Firewall**: Must allow VXLAN (UDP 4789) from all VTEP subnets including `100.64.0.0/24`
3. **BGP Advertisement**: GCP routers must advertise full 192.168.11.0/24 subnet for VTEP reachability
4. **Route Reflector**: Use spine as RR to avoid full mesh on-prem; GCP uses mesh topology
5. **Inter-subnet routing requirements** (leafl3test ↔ GCP):
   - Same VRF name ("red") and VXLAN VNI (100) on both sides
   - leafl3test: `redistribute connected` in BGP VRF for Type-5 route advertisement
   - GCP (OpenPERouter): L3VNI CRD with matching VNI and VRF
   - Matching Route Targets for route import/export (auto-derived from ASN:VNI)
6. **IPv4 forwarding**: Router pods require `net.ipv4.ip_forward=1` for inter-subnet routing.
   OpenPERouter enables this automatically (see [PR #212](https://github.com/openperouter/openperouter/pull/212)).
   On GCP/OpenShift with crio runtime, the sysctl may be reset by the container runtime.

## Cleanup

```bash
# GCP
cd evpnvirtonopenshift/scripts
./setup-gcp.sh cleanup

# On-prem

make -C ./openperouter undeploy-hybrid
```

## References

- OpenPERouter (GCP): https://github.com/yourorg/openperouter/tree/dnm-gcp
- EVPN VirtOnOpenShift (GCP): https://github.com/yourorg/evpnvirtonopenshift/tree/gcp
