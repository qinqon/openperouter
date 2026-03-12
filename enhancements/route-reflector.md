# Enhancement: Internal iBGP Route Reflector

## Summary

In environments where the external network does not support EVPN, OpenPERouter cannot distribute EVPN routes between router pods via the fabric. Without an alternative the only option is a full-mesh iBGP topology, which does not scale.

This enhancement adds an internal iBGP Route Reflector for EVPN distribution between router pods:

- **East/West**: iBGP EVPN via an internal RR. VXLAN data plane goes directly between nodes.
- **North/South**: eBGP with the ToR for IPv4/IPv6 (unchanged).

No dedicated FRR pods are added. A lightweight **RR controller** Deployment (2 replicas) configures the existing router pod FRR process on two nodes as route reflectors. Kubernetes scheduling determines which nodes are RRs — no leader election, no new CRDs, no API changes.

## Motivation

- **Cloud environments**: managed routers typically do not support EVPN
- **Hybrid deployments**: depending on the on-prem ToR for route reflection adds latency and cost to every East/West flow
- **Full-mesh iBGP**: N*(N-1)/2 sessions, does not scale

### Goals

- Enable East/West EVPN without requiring EVPN support from the external fabric
- Keep East/West data plane traffic within the cluster (no hairpin through the ToR)
- HA without leader election
- No new API types — opt-in by deploying the RR controller

### Non-Goals

- Exposing RR peering to external routers
- Dedicated standalone FRR RR pods

## Design

### How It Works

The RR controller is a 2-replica Deployment. Each replica lands on a different node (anti-affinity) that runs a router pod (affinity). On startup it:

1. Reads the local node's underlay NIC IP from the `openperouter.io/underlay-ip` annotation (written by the hostcontroller)
2. Labels the node `openperouter.io/rr=true`
3. Creates a `RawFRRConfig` that configures the local router pod FRR as an RR: `bgp listen range`, `route-reflector-client`

The per-node hostcontroller (DaemonSet) discovers RR-labeled nodes and adds them as iBGP neighbors on client nodes. On RR nodes it merges the `RawFRRConfig` into the FRR config.

Deploying the RR controller is the only opt-in required. No changes to the Underlay CR are needed.

### Session Topology

```
            ToR (eBGP)

  RR node A ←—— iBGP ——→ RR node B       (explicit neighbors, full mesh)
       ↑  bgp listen range         ↑
       |  route-reflector-client    |
       └────────────┬───────────────┘
                    │
          client C          client D      (connect to both RRs)
```

- **Clients → RRs**: clients initiate, RRs accept passively via `bgp listen range` on the underlay NIC subnet
- **RR ↔ RR**: explicit iBGP peers (not via listen range), so they are not route-reflector-clients of each other
- **All nodes → ToR**: eBGP unchanged, `allowas-in` applies only to eBGP neighbors

### Underlay IP Discovery

The hostcontroller reads the moved underlay NIC's IP with mask (e.g. `192.168.11.3/24`) from inside the router pod network namespace and writes it to the `openperouter.io/underlay-ip` node annotation. The RR controller derives the `bgp listen range` CIDR by zeroing the host bits. Client nodes read the RR node's annotation to get the peer IP.

> **Note:** The `openperouter.io/underlay-ip` node annotation is a temporary discovery mechanism introduced by this PoC. It is expected to be replaced by a per-node Underlay status subresource in a future iteration.

### Failure and Rescheduling

When an RR controller pod is evicted:

1. Graceful shutdown removes the `RawFRRConfig` and `rr=true` label
2. The hostcontroller on that node reverts to client FRR config
3. Client nodes detect the label removal and drop the iBGP neighbor
4. Kubernetes reschedules the pod on a new node → that node becomes the new RR

### Installation

**Kustomize:**
```
make deploy-with-rr
```

**Helm:**
```
helm install openperouter charts/openperouter/ --set routeReflector.enabled=true
```

**Operator** (`OpenPERouter` CR):
```yaml
spec:
  routeReflector:
    enabled: true
```

### Verification

A verification script (`hack/rr-poc-verify.sh`) checks the full stack:

- Node labels and underlay-ip annotations
- RR controller pods and RawFRRConfigs
- BGP session status per node (dynamic clients shown with `*` prefix)
- EVPN type-3 best path is `*>i` (iBGP from RR), not the ToR eBGP path
- VXLAN capture confirms direct node-to-node encapsulation
- Zero VXLAN packets via the ToR IP

## Alternatives Considered

### Standalone FRR RR Pods

Dedicated FRR pods on the cluster network. Rejected: requires cluster-to-underlay routing, adds separate FRR processes, pod IPs are unstable.

### Full-mesh iBGP

N*(N-1)/2 sessions. Does not scale.

### FRR-K8s as Route Reflector

Use MetalLB's FRR operator `raw.config`. Rejected: explicitly unsupported/experimental, cross-system coordination, upgrade risk.

## References

- RFC 4456 — BGP Route Reflection
- FRR `bgp listen range` — https://docs.frrouting.org/en/latest/bgp.html
- PoC branch — https://github.com/qinqon/openperouter/tree/poc-router-reflector
