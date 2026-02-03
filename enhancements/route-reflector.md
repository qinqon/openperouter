# Enhancement: BGP Route Reflector — Hybrid Peering via RR Controller

## Summary

In cloud provider environments and hybrid deployments, the external network infrastructure often does not support the EVPN address family. This prevents OpenPERouter from distributing EVPN routes between router pods via the external fabric. Without an alternative, the only option is a full-mesh iBGP topology between all router pods, which does not scale (N*(N-1)/2 sessions).

This enhancement introduces a **Hybrid Peering** design:

- **East/West (inter-router)**: iBGP with an internal Route Reflector for EVPN distribution. Control plane: Router → RR → Router. Data plane transport is determined by the customer's infrastructure.
- **North/South (ToR/External)**: Direct eBGP with ToR for IPv4/IPv6 (existing behavior, unchanged).

The Route Reflector is not a separate FRR pod. Instead, a new **RR controller** (a 2-replica Kubernetes Deployment) runs on nodes where router pods run and configures the local router pod's FRR process as an RR node by creating a `RawFRRConfig` object. Kubernetes scheduling determines which two nodes become RRs; no leader election is required.

## Motivation

In cloud provider environments (AWS, GCP, Azure, etc.), the managed cloud router infrastructure typically does not support EVPN address family. This creates a challenge for OpenPERouter deployments that need to distribute EVPN routes between nodes:

- **Cloud routers** only support basic IPv4/IPv6 BGP, not EVPN
- **EVPN routes** cannot be distributed via the cloud network fabric
- **Full-mesh iBGP** between all router pods is unmanageable at scale (N*(N-1)/2 sessions)

A Route Reflector deployed within the cluster solves this by:
- Handling EVPN route distribution internally between router pods
- Allowing router pods to continue peering with external routers for IPv4/IPv6 connectivity

### Use Case: Cloud Provider Environments Without EVPN Support

```
┌─────────────────────────────────────────────────────────────┐
│                    Cloud Provider Network                   │
│                                                             │
│                   Cloud Router (no EVPN)                    │
│                                                             │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           │ eBGP (IPv4/IPv6 only, no EVPN)
                           │
┌──────────────────────────▼───────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                    │
│  │ Router   │  │ Router   │  │ Router   │                    │
│  │ Pod 1    │  │ Pod 2    │  │ Pod 3    │                    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                    │
│       │             │             │                          │
│       │   iBGP EVPN (via RR on Pod 1 and Pod 2)              │
│       │             │             │                          │
│       └─────────────┼─────────────┘                          │
│                     │                                        │
│     ┌───────────────┴───────────────┐                        │
│     │ Router Pod 1 FRR acts as RR   │ ← RR controller on     │
│     │ Router Pod 2 FRR acts as RR   │   nodes 1 and 2        │
│     └───────────────────────────────┘                        │
└──────────────────────────────────────────────────────────────┘
```

### Use Case: Hybrid Cloud Cost and Efficiency

In hybrid deployments, depending on the on-prem ToR for EVPN route reflection adds latency and cost to every East/West flow. An in-cluster RR keeps East/West traffic local:

**Route Flow in Hybrid Scenario:**

| Route Type | Flow |
|------------|------|
| External EVPN (from ToR) | ToR → eBGP → Router Pod → iBGP → RR → reflects to other Router Pods |
| Internal EVPN (local VMs) | Router Pod → iBGP → RR → reflects to other Router Pods |
| Internal EVPN to external | Router Pod → eBGP → ToR |

### Goals

- Configure Underlay in non-EVPN-capable ToR environments without using a BGP mesh
- Keep all East/West EVPN control plane traffic within the cluster
- Support high availability without leader election
- Reuse existing router pod FRR processes — no additional FRR deployments

### Non-Goals

- Expose RR peering with external routers (router pods handle external connectivity)
- Dedicated standalone FRR RR pods

## Design Details

### Architecture

```
RR Controller Pod-1 (on Node A)        RR Controller Pod-2 (on Node B)
  creates RawFRRConfig → Node A           creates RawFRRConfig → Node B
  labels Node A: rr=true                 labels Node B: rr=true
  annotates Node A underlay-ip           annotates Node B underlay-ip

hostcontroller on Node A:               hostcontroller on Node B:
  merges RawFRRConfig                     merges RawFRRConfig
  → FRR acts as RR                        → FRR acts as RR

hostcontroller on Node C, D, ...:
  reads nodes with rr=true label
  → adds Node A and Node B underlay IPs as iBGP neighbors
  → FRR acts as RR client
```

**Key properties:**
- No dedicated FRR RR pods — the existing router pod FRR process acts as RR on nodes where the RR controller lands
- No leader election — Kubernetes scheduling determines which 2 nodes are RRs
- Active-active HA: 2 RR controller replicas, each configuring its local node's router pod as RR
- No cluster default network — all iBGP sessions use underlay IPs (VTEP IPs)
- `allowas-in` applies only to eBGP neighbors, not iBGP (RR) neighbors

### Components

#### New: RR Controller (`Deployment`, 2 replicas)

- Runs only on nodes where router pods run (pod affinity)
- Anti-affinity between replicas ensures they land on different nodes
- Each pod configures its LOCAL node's router pod as RR by:
  1. Creating/updating a `RawFRRConfig` for its node with RR BGP snippets
  2. Labeling its node with `openperouter.io/rr: "true"`
  3. Writing its local underlay IP to the node annotation `openperouter.io/underlay-ip`
- On eviction/deletion: removes the `RawFRRConfig` and node label → hostcontroller reverts node to client config. Kubernetes reschedules the pod on another node → that node becomes the new RR.

#### Updated: Per-node hostcontroller (DaemonSet)

- Merges `RawFRRConfig` into full FRR config (existing behavior)
- Writes the local node's underlay IP to `openperouter.io/underlay-ip` annotation
- Watches nodes with label `openperouter.io/rr: "true"`, reads their `openperouter.io/underlay-ip` annotation, and adds them as iBGP neighbors (on non-RR nodes)

### Failure and Rescheduling

When RR Controller Pod-1 is evicted from Node A:

1. Pod cleanup: deletes `RawFRRConfig` for Node A, removes `openperouter.io/rr` label (via finalizer or graceful shutdown)
2. hostcontroller on Node A: detects RawFRRConfig gone → reverts to client FRR config
3. hostcontrollers on C, D: detect Node A label removed → remove iBGP neighbor for Node A
4. Kubernetes reschedules Pod-1 on Node E → Node E becomes new RR

### Node Annotations and Labels

| Key | Value | Set by | Purpose |
|-----|-------|--------|---------|
| `openperouter.io/rr` (label) | `"true"` | RR controller | Marks node as RR |
| `openperouter.io/underlay-ip` (annotation) | IP string | hostcontroller, RR controller | Underlay/VTEP IP of node |

The underlay IP source:
- `vtepCIDR` case: `ipam.VTEPIp(vtepCIDR, nodeIndex)` — derived from the CIDR and node index
- `vtepInterface` case: read from the actual network interface (not yet implemented)

### Opt-in: deploying the RR controller is the only configuration required

No changes are needed to the `Underlay` CR. The `Underlay` EVPN `vtepCIDR` is used
directly as the `bgp listen range` on RR nodes. Deploying the RR controller
Deployment is the sole opt-in signal — when no RR controller pods are running,
no RR-labeled nodes exist, and the system behaves identically to a standard deployment.

### Example Underlay Configuration

```yaml
apiVersion: openpe.openperouter.github.io/v1alpha1
kind: Underlay
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  asn: 64514
  routerIDCIDR: "10.0.0.0/24"
  nics:
    - "eth1"
  evpn:
    vtepCIDR: "100.65.0.0/24"

  # External peering (eBGP, North/South, unchanged)
  neighbors:
    - address: "192.168.11.2"
      asn: 64512

  # No routeReflector field needed — deploy the RR controller to enable East/West iBGP.
```

### Connection Initialization

**Clients initiate, the RR accepts passively.**

The RR controller configures `bgp listen range <vtepCIDR> peer-group CLIENTS` on the RR node.
The hostcontroller on each client node discovers RR nodes via the `openperouter.io/rr=true` label and
adds explicit `neighbor <rrIP> remote-as <ASN>` statements — those outbound connections are accepted
by the RR's listen range and automatically assigned to the CLIENTS peer-group as route-reflector-clients.

This keeps the RR controller simple: it only configures its own node and never needs to track individual client IPs.

### HA: Two RR Nodes

When two RR controller replicas are running (on node-0 and node-1), the hostcontroller on each RR node
discovers the other RR via the label and adds it as an explicit iBGP neighbor. In FRR, an explicit
`neighbor <IP>` statement takes precedence over a matching `bgp listen range` entry, so the two RRs
peer with each other as **regular iBGP peers** — not as route-reflector-clients of each other.

```
Session map (4 nodes, 2 RRs):

            ToR (ASN 64512)
            192.168.11.2
            eBGP ↕ (all 4 nodes)

  node-0 RR ←——— iBGP full mesh ———→ node-1 RR
  100.65.0.0   (explicit neighbor,     100.65.0.1
  |  bgp listen  NOT via listen range)   |  bgp listen
  |  range /24                           |  range /24
  |  route-reflector-client              |  route-reflector-client
  └──────────────┬────────────────────────┘
                 │  clients connect to BOTH RRs
        ┌────────┴────────┐
      node-2            node-3
    100.65.0.2         100.65.0.3
```

### FRR Configuration

**RR node** (from `RawFRRConfig` created by RR controller) — appended to the main FRR config:

```
router bgp <ASN>
  bgp cluster-id <routerID>
  neighbor CLIENTS peer-group
  neighbor CLIENTS remote-as <ASN>
  bgp listen range <vtepCIDR> peer-group CLIENTS   # passively accepts client connections
  address-family l2vpn evpn
    neighbor CLIENTS activate
    neighbor CLIENTS route-reflector-client
  exit-address-family
```

FRR merges multiple `router bgp <ASN>` stanzas for the same ASN, so this snippet is combined with
the main underlay BGP block generated by the hostcontroller.

**RR node — inter-RR peering** (added by hostcontroller, same as client nodes):

```
  # explicit neighbor to the other RR node — takes precedence over bgp listen range,
  # so the other RR is NOT placed in CLIENTS and NOT treated as a route-reflector-client
  neighbor <otherRRUnderlayIP> remote-as <ASN>
  address-family l2vpn evpn
    neighbor <otherRRUnderlayIP> activate
  exit-address-family
```

**Client node** (hostcontroller adds iBGP neighbors for each RR node):

```
  neighbor <rrNode1UnderlayIP> remote-as <ASN>
  neighbor <rrNode2UnderlayIP> remote-as <ASN>
  address-family l2vpn evpn
    neighbor <rrNode1UnderlayIP> activate   # no allowas-in for iBGP
    neighbor <rrNode2UnderlayIP> activate
  exit-address-family
```

**`allowas-in` — eBGP only** (`underlay_evpn.tmpl`):

```
  address-family l2vpn evpn
{{- range .Underlay.Neighbors }}
    neighbor {{ .Addr }} activate
    {{- if ne .ASN $.Underlay.MyASN }}
    neighbor {{ .Addr }} allowas-in
    {{- end }}
{{- end }}
    advertise-all-vni
    advertise-svi-ip
  exit-address-family
```

### Implementation Summary

#### Files Modified

| File | Change |
|------|--------|
| `internal/frr/config.go` | Added `RRClients []NeighborConfig` to `UnderlayConfig` |
| `internal/conversion/api.go` | Added `RRNodeUnderlayIPs []string` to `ApiConfigData` |
| `internal/conversion/frr_conversion.go` | Populates `RRClients` from `RRNodeUnderlayIPs`; added `UnderlayIPForNode()` helper |
| `internal/frr/templates/underlay_evpn.tmpl` | Conditional `allowas-in` for eBGP only |
| `internal/frr/templates/frr.tmpl` | Added RR client neighbor entries in l2vpn evpn AF |
| `internal/controller/routerconfiguration/underlay_vni_controller.go` | Writes underlay-ip annotation; discovers RR nodes; watches RR label/annotation changes |
| `cmd/hostcontroller/main.go` | Removed node cache filter (all nodes cached for RR label watching) |

#### Files Added

| File | Purpose |
|------|---------|
| `internal/controller/rrcontroller/rrcontroller.go` | RR controller reconcile loop |
| `cmd/rrcontroller/main.go` | RR controller binary entrypoint |
| `config/rr-controller/deployment.yaml` | RR controller Deployment with affinity rules |
| `config/rr-controller/rbac.yaml` | ServiceAccount, ClusterRole, ClusterRoleBinding |
| `config/rr-controller/kustomization.yaml` | Kustomize entry for rr-controller manifests |

### RR Controller Deployment

```yaml
spec:
  replicas: 2
  template:
    spec:
      affinity:
        # Must land on a node running a router pod
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: router
            topologyKey: kubernetes.io/hostname
        # Two replicas must be on different nodes
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: openperouter-rr-controller
            topologyKey: kubernetes.io/hostname
```

## Verification

1. Deploy RR controller:
   ```
   kubectl apply -k config/rr-controller/
   ```

2. Verify RR controller pods landed on different nodes:
   ```
   kubectl get pods -n openperouter-system -l app=openperouter-rr-controller -o wide
   ```

3. Verify RR nodes are labeled:
   ```
   kubectl get nodes -l openperouter.io/rr=true
   ```

4. Verify `RawFRRConfig` objects created for RR nodes:
   ```
   kubectl get rawfrrconfigs -n openperouter-system
   ```

5. Verify underlay-ip annotations on all nodes:
   ```
   kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openperouter\.io/underlay-ip}{"\n"}{end}'
   ```

6. Verify RR node FRR has `bgp listen range` and `route-reflector-client`:
   ```
   kubectl exec -n openperouter-system <rr-router-pod> -c frr -- cat /etc/frr/frr.conf
   ```

7. Verify client node FRR has iBGP neighbors pointing to RR nodes:
   ```
   kubectl exec -n openperouter-system <client-router-pod> -c frr -- cat /etc/frr/frr.conf
   ```

8. Verify `allowas-in` absent for iBGP neighbors, present for eBGP (ToR) neighbors.

9. Verify BGP sessions UP:
   ```
   vtysh -c "show bgp summary"
   ```

10. Verify EVPN routes reflected:
    ```
    vtysh -c "show bgp l2vpn evpn"
    ```

11. Simulate RR controller pod eviction: verify it reschedules on a new node, new node becomes RR, old node reverts to client, BGP reconverges.

## Alternatives Considered

### Standalone Dedicated FRR RR Pods

Deploy dedicated FRR pods as a Kubernetes Deployment using the cluster default network. Router pods peer with RR pod IPs via the cluster network. Rejected because:

- Requires the cluster default network to be routable to router pod underlay interfaces, which conflicts with the goal of using underlay IPs for all iBGP sessions
- Adds a separate FRR process per RR node; the proposed approach reuses existing router pod FRR processes
- Pod IP instability: cluster pod IPs change on restart, requiring dynamic discovery

### Full-mesh iBGP

N*(N-1)/2 iBGP sessions between all router pods. Does not scale and requires static configuration of all peer IPs.

### FRR-K8s as Route Reflector

Leverage existing FRR-K8s (MetalLB FRR operator) installations to act as RRs on selected nodes using the `raw.config` feature. Rejected because:

- `raw.config` is explicitly marked unsupported and experimental
- Adds dependency on FRR-K8s CRD stability across upgrades
- Requires coordination between two separate systems

## References

- RFC 4456 - BGP Route Reflection: https://datatracker.ietf.org/doc/html/rfc4456
- FRR `bgp listen range`: https://docs.frrouting.org/en/latest/bgp.html
