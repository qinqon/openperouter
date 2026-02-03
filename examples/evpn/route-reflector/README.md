# Route Reflector Example

This example demonstrates using the internal BGP Route Reflector for EVPN route distribution between router pods.

## Use Cases

- **Cloud environments**: Where the cloud router (ToR) doesn't support EVPN or route reflection
- **Hybrid deployments**: Where you want East/West EVPN traffic independent of external infrastructure
- **Scale**: Avoids full-mesh iBGP between router pods (N*(N-1)/2 sessions)

## Architecture

```
                    ┌─────────────────────┐
                    │   External ToR      │ ASN 64512
                    └──────────┬──────────┘
                               │ eBGP (IPv4/IPv6/EVPN)
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
    ┌────▼─────┐         ┌─────▼────┐         ┌──────▼───┐
    │ Router   │         │ Router   │         │ Router   │ ASN 64514
    │ Pod 1    │         │ Pod 2    │         │ Pod 3    │
    └────┬─────┘         └────┬─────┘         └────┬─────┘
         │                    │                    │
         │      iBGP EVPN (cluster network)        │
         │                    │                    │
         └────────────────────┼────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │                   │
              ┌─────▼─────┐       ┌─────▼─────┐
              │ RR Pod 0  │       │ RR Pod 1  │ ASN 64514
              └───────────┘       └───────────┘

              DNS: openperouter-rr-{0,1}.openperouter-rr.openperouter-system.svc
```

## Prerequisites

- Kubernetes cluster with Multus CNI
- OpenPERouter deployed with Route Reflector enabled

## Deployment

### Step 1: Deploy OpenPERouter with Route Reflector

**Using Helm:**
```bash
helm upgrade --install openperouter ./charts/openperouter \
  --namespace openperouter-system --create-namespace \
  --set routeReflector.enabled=true \
  --set routeReflector.asn=64514 \
  --set routeReflector.clusterID="1.1.1.1" \
  --set routeReflector.podCIDR="10.244.0.0/16"
```

**Using make deploy (kustomize):**
```bash
make deploy
```
Note: With kustomize, the Route Reflector is always deployed. Edit `config/route-reflector/route-reflector.yaml` to customize ASN/podCIDR.

### Step 2: Verify Route Reflector is running

```bash
kubectl get pods -n openperouter-system -l app.kubernetes.io/component=route-reflector
```

Expected output:
```
NAME                 READY   STATUS    RESTARTS   AGE
openperouter-rr-0    1/1     Running   0          1m
openperouter-rr-1    1/1     Running   0          1m
```

### Step 3: Apply OpenPE configuration

```bash
kubectl apply -f openpe.yaml
```

This creates:
- **L3VNI** (VNI 100) - VRF "red" with host session
- **L2VNI** (VNI 110) - Layer 2 overlay with gateway
- **Underlay** - Peers with external ToR + both RR replicas

### Step 4: Deploy workload pods

```bash
kubectl apply -f workload.yaml
```

This creates:
- NetworkAttachmentDefinition for macvlan on the L2VNI bridge
- Two test pods on different nodes connected via the overlay

## Verification

### Check RR BGP sessions

```bash
kubectl exec -n openperouter-system openperouter-rr-0 -- vtysh -c "show bgp summary"
```

### Check EVPN routes on RR

```bash
kubectl exec -n openperouter-system openperouter-rr-0 -- vtysh -c "show bgp l2vpn evpn"
```

### Test connectivity between pods

```bash
kubectl exec first -- curl -s http://192.170.1.4:8090/hostname
kubectl exec second -- curl -s http://192.170.1.3:8090/hostname
```

## Configuration Details

### Underlay with RR neighbors

The Underlay configures router pods to peer with:
1. External ToR (eBGP) - different ASN
2. Route Reflector replicas (iBGP) - same ASN

```yaml
neighbors:
  # External ToR (eBGP)
  - asn: 64512
    address: 192.168.11.2

  # Internal RR (iBGP) - same ASN = iBGP
  - asn: 64514
    address: openperouter-rr-0.openperouter-rr.openperouter-system.svc
  - asn: 64514
    address: openperouter-rr-1.openperouter-rr.openperouter-system.svc
```

### RR FRR Configuration

The Route Reflector uses dynamic peer acceptance:
- `bgp listen range <podCIDR>` - accepts connections from any pod
- `neighbor CLIENTS route-reflector-client` - reflects routes to clients
- `bgp cluster-id` - prevents routing loops

## Troubleshooting

### RR not accepting connections

Check that the podCIDR matches your cluster's pod network:
```bash
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

### Router pods not connecting to RR

Verify DNS resolution works:
```bash
kubectl exec -n openperouter-system <router-pod> -- \
  nslookup openperouter-rr-0.openperouter-rr.openperouter-system.svc
```

### EVPN routes not being reflected

Check RR received routes:
```bash
kubectl exec -n openperouter-system openperouter-rr-0 -- \
  vtysh -c "show bgp l2vpn evpn summary"
```
