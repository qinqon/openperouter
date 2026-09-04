---
weight: 40
title: "EVPN Configuration"
description: "How to configure OpenPERouter"
icon: "article"
date: "2025-06-15T15:03:22+02:00"
lastmod: "2025-06-15T15:03:22+02:00"
toc: true
---

## Underlay Configuration

In addition to the configuration described in the [underlay configuration section]({{< ref "configuration/#underlay-configuration" >}}), the VTEP (Virtual Tunnel End Point) source must be configured via the `tunnelEndpoint.cidrs` field.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  asn: 64514
  tunnelEndpoint:
    cidrs:
    - 100.65.0.0/24
  interfaces:
    - type: NetworkDevice
      networkDevice:
        interfaceName: toswitch
  neighbors:
    - asn: 64512
      address: 192.168.11.2
```

The `tunnelEndpoint.cidrs` field defines the IP range used for VTEP addresses. OpenPERouter automatically assigns a unique VTEP IP to each node from this range. At least one CIDR (IPv4 or IPv6) is required, and both may be specified for dual-stack operation. For example, with `100.65.0.0/24`:

- Node 1: `100.65.0.1`
- Node 2: `100.65.0.2`
- Node 3: `100.65.0.3`
- etc.

By default the allocated IP is assigned to the loopback interface inside the router namespace, and OpenPERouter advertises the VTEP IP to the fabric over the BGP underlay session. The loopback decouples the VTEP from any single uplink: with multiple underlay interfaces, the tunnels survive the loss of one of them.

#### VTEP on a CNI-Provisioned Interface

Some uplinks cannot deliver traffic to an address assigned to the loopback. An `ipvlan` interface in L3 mode, the interface of choice in cloud networks that reject additional source MAC addresses, only delivers incoming packets to addresses assigned to the ipvlan interface itself, so a loopback VTEP never receives the return VXLAN traffic.

For these cases the `tunnelEndpoint.interfaceName` field places the allocated VTEP IP on a [CNI-provisioned interface]({{< ref "configuration/#cni-provisioned-interfaces" >}}) instead of the loopback, and the VXLAN devices use that interface as their source device:

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: underlay
  namespace: openperouter-system
spec:
  asn: 65001
  tunnelEndpoint:
    interfaceName: net1
    cidrs:
    - 192.168.11.0/24
  interfaces:
    - type: CNIDevice
      cniDevice:
        type: RawConfig
        interfaceName: net1
        rawConfig:
          cniVersion: "1.0.0"
          name: ipvlan-underlay
          plugins:
            - type: ipvlan
              master: eth0
              mode: l3
              capabilities:
                ips: true
              ipam:
                type: static
                routes:
                  - dst: 10.250.1.0/24
  neighbors:
    - asn: 64515
      address: 10.250.1.3
      properties:
        - type: ebgpMultiHop
          ebgpMultiHop:
            ttl: 10
```

`cidrs` remains the source of the VTEP IP: OpenPERouter derives it from the node index as usual, and hands it to the CNI chain through the `ips` capability argument so that the `static` IPAM plugin assigns it to the interface at CNI ADD time. Because of this, the referenced CNI configuration must:

- be the only entry of `interfaces`, since a VTEP bound to an uplink gives up the loopback's multi-uplink redundancy;
- be a single `ipvlan` plugin in `l3` mode with `static` IPAM declaring `capabilities: {ips: true}`;
- not set `ipam.addresses` nor `runtimeConfig.ips`, as OpenPERouter owns the addresses of that interface;
- not set `disableCheck`, since CNI CHECK is what detects drift.

`interfaceName` is immutable: moving the VTEP between the loopback and an interface requires deleting and recreating the Underlay. Changing `cidrs` re-provisions the interface with the new address after tearing down the VNIs bound to it. The field is not supported together with SRv6.

The surrounding network must route the derived address to the node (e.g. a GCP alias IP range, an AWS secondary private IP, an Azure secondary IP configuration or an OpenStack allowed address pair); OpenPERouter does not configure the cloud provider.

#### IPv6 and Dual-Stack VTEP

IPv6-only or dual-stack (IPv4 + IPv6) VTEP configurations are supported:

```yaml
  tunnelEndpoint:
    cidrs:
    - 100.65.0.0/24
    - fd00:64::/120
```

When both IPv4 and IPv6 CIDRs are specified, individual VNIs can select which address family to use via the `underlayAddressFamily` field on the L3VNI or L2VNI resource. When omitted, it defaults to the available family (IPv4 preferred in dual-stack).

### Configuration Fields

| Field | Type | Description | Required |
|-------|------|-------------|----------|
| `asn` | integer | Local ASN for BGP sessions | Yes |
| `tunnelEndpoint.cidrs` | array | CIDR blocks for VTEP IP allocation, at most one per address family | Yes |
| `tunnelEndpoint.interfaceName` | string | CNI-provisioned interface carrying the VTEP IP instead of the loopback. See [VTEP on a CNI-Provisioned Interface](#vtep-on-a-cni-provisioned-interface) | No |
| `interfaces` | array | List of underlay interfaces to use for connectivity. Each entry is a discriminated union; the `NetworkDevice` type moves an existing host network device into the router namespace, while the `CNIDevice` type provisions an interface inside the router namespace via a CNI plugin. All entries must use the same type: mixing `NetworkDevice` and `CNIDevice` interfaces is rejected | Yes |
| `neighbors` | array | List of BGP neighbors to peer with | Yes |
| `nodeSelector` | object | Label selector to target specific nodes (applies to all nodes if omitted) | No |
| `gracefulRestart` | object | Enables BGP Graceful Restart when present. See [Graceful Restart]({{< ref "graceful-restart" >}}). | No |

## L3 VNI Configuration

L3 VNI (Virtual Network Identifier) configurations define EVPN L3 overlays. Each L3VNI creates a separate routing domain and BGP session with the host.

### Basic L3VNI Configuration

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L3VNI
metadata:
  name: blue
  namespace: openperouter-system
spec:
  vrf: blue
  hostSession:
    asn: 64514
    hostASN: 64515
    localCIDR:
      ipv4: 192.169.11.0/24
  vni: 200

```

### Configuration Fields

| Field | Type | Description | Required |
|-------|------|-------------|----------|
| `vrf` | string | Name of the VRF (Virtual Routing and Forwarding) instance | Yes |
| `vni` | integer | Virtual Network Identifier (1-16777215) | Yes |
| `underlayAddressFamily` | string | VTEP address family for this VNI (`IPv4` or `IPv6`). Defaults to available family (IPv4 preferred in dual-stack). | No |
| `hostSession.asn` | integer | Router ASN for BGP session with host | Yes |
| `hostSession.hostASN` | integer | Host ASN for BGP session | Yes |
| `hostSession.localCIDR` | string | CIDR for veth pair IP allocation | Yes |
| `nodeSelector` | object | Label selector to target specific nodes (applies to all nodes if omitted) | No |

### Multiple VNIs Example

You can create multiple VNIs for different network segments:

```yaml
# Production VNI
apiVersion: network.openperouter.io/v1alpha1
kind: L3VNI
metadata:
  name: signal
  namespace: openperouter-system
spec:
  vrf: signal
  vni: 100
  hostSession:
    asn: 64514
    hostASN: 64515
    localCIDR:
      ipv4: 192.168.10.0/24
---
# Development VNI
apiVersion: network.openperouter.io/v1alpha1
kind: L3VNI
metadata:
  name: oam
  namespace: openperouter-system
spec:
  vrf: oam
  vni: 200
  hostSession:
    asn: 64514
    hostASN: 64515
    localCIDR:
      ipv4: 192.168.20.0/24
```

## What Happens During Reconciliation

When you create or update VNI configurations, OpenPERouter automatically:

1. **Creates Network Interfaces**: Sets up VXLAN interface and Linux VRF named after the VNI
2. **Establishes Connectivity**: Creates veth pair and moves one end to the router's namespace
3. **Adjusts Veth MTU**: Sets the MTU on both veth legs to the underlay NIC's MTU minus 50 bytes to
   account for VXLan encapsulation overhead. MTU calculation is per VRF.
4. **Assigns IP Addresses**: Allocates IPs from the `localCIDR` range:
   - Router side: First IP in the CIDR (e.g., `192.169.11.1`)
   - Host side: Each node gets a free IP in the CIDR, starting from the second (e.g., `192.169.11.15`)
5. **Creates BGP Session**: Opens BGP session between router and host using the specified ASNs

## L2VNI Configuration

L2VNIs provide Layer 2 connectivity across nodes using EVPN tunnels. Unlike L3VNIs, L2VNIs extend Layer 2 domains rather than routing domains.

### Configuration Fields

| Field | Type | Description | Required |
|-------|------|-------------|----------|
| `vni` | integer | Virtual Network Identifier for the EVPN tunnel | Yes |
| `routingDomain` | object | Attaches this L2VNI to a routing domain provided by an L3VNI or L3VPN. When omitted, the L2VNI is a disconnected overlay (east-west L2 only, no VRF, no gateway). | No |
| `routingDomain.type` | string | Type of routing domain provider (`L3VNI` or `L3VPN`) | Yes (when routingDomain is set) |
| `routingDomain.l3vni.name` | string | metadata.name of the L3VNI that provides the routing domain | Yes (when type is `L3VNI`) |
| `routingDomain.l3vpn.name` | string | metadata.name of the L3VPN that provides the routing domain | Yes (when type is `L3VPN`) |
| `gatewayIPs` | string array | IP addresses in CIDR notation for the distributed anycast gateway. Cannot be set without routingDomain. Max 2 (one IPv4, one IPv6). | No |
| `underlayAddressFamily` | string | VTEP address family for this VNI (`IPv4` or `IPv6`). Defaults to available family (IPv4 preferred in dual-stack). | No |
| `hostMaster.type` | string | Type of host interface management (`LinuxBridge` or `OVSBridge`) | Yes |
| `hostMaster.linuxBridge.lifecycle` | string | How the Linux bridge is provisioned (`Managed` or `External`) | Yes |
| `hostMaster.linuxBridge.name` | string | Name of the Linux bridge to attach to. Only valid when `External` | Only when `External` |
| `hostMaster.ovsBridge.lifecycle` | string | How the OVS bridge is provisioned (`Managed` or `External`) | Yes |
| `hostMaster.ovsBridge.name` | string | Name of the OVS bridge to attach to. Only valid when `External` | Only when `External` |
| `nodeSelector` | object | Label selector to target specific nodes (applies to all nodes if omitted) | No |

### L2VNI Example

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2red
  namespace: openperouter-system
spec:
  vni: 210
  routingDomain:
    type: L3VNI
    l3vni:
      name: red
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: Managed
```

## What Happens During Reconciliation

When you create or update VNI configurations, OpenPERouter automatically:

1. **Creates Network Interfaces**: Sets up VXLAN interface, and a Linux VRF named after the VNI only when `routingDomain` is configured
2. **Establishes Connectivity**: Creates veth pair and moves one end to the router's namespace
3. **Adjusts Veth MTU**: Sets the MTU on both veth legs to the underlay NIC's MTU minus 50 bytes to account for VXLan encapsulation overhead
4. **Attaches the veth**: the veth is connected to the bridge corresponding to the l2 domain
5. **Optionally creates a bridge on the host**: if the bridge `lifecycle` is `Managed`, named `br-hs-<VNI>`
6. **Optionally connects the host veth to the bridge on the host**: if the bridge `lifecycle` is `Managed` or a name
is set

## Per-Node Configuration

All EVPN resources (Underlay with EVPN, L3VNI, and L2VNI) support the optional `nodeSelector` field, which allows you to target specific configurations to specific nodes. This is useful for:

- Multi-rack deployments with different VNIs per rack
- Multi-datacenter clusters with zone-specific configurations
- Selective deployment to worker nodes only
- Hardware-specific configurations

For detailed information and examples, see the [Node Selector Configuration]({{< ref "node-selector.md" >}}) documentation.

## API Reference

For detailed information about all available configuration fields, validation rules, and API specifications, see the [API Reference]({{< ref "api-reference.md" >}}) documentation.
