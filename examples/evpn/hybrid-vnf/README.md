# Hybrid VNF: VLAN L2 stretch to a GCP EVPN fabric

This example stretches a Layer 2 VLAN from an on-premises **VNF** (a single
OpenPERouter instance running as a systemd/Podman service, **no Kubernetes**)
to a GCP OpenShift cluster running OpenPERouter, over an IPsec Cloud VPN, using
EVPN/VXLAN.

It is the cloud-VPN, single-VNF variant of [`../hybrid`](../hybrid): the
on-prem side is not a Kubernetes cluster but one container-based router that
also terminates the VPN, so you can exercise the cloud-VPN overhead and the
VLAN attachment without a second cluster.

**GCP-side status: verified working end-to-end** (BGP full mesh, EVPN Type-2/3
routes, VXLAN datapath, pod-to-pod ping across nodes). The on-prem VNF steps
are implemented but not yet run against a real laptop/VPN in this branch.

```
        ON-PREM (laptop)                     GCP OpenShift (ellorent-vlan-evpn)
  ┌──────────────────────────┐    ┌──────────────────────────────────────────────────┐
  │ OpenPERouter VNF (systemd)│    │ master-0/1/2 (route reflectors, ASN 65001)        │
  │  FRR + reloader+strongSwan│    │   ipvlan-l3 net1 on br-ex, GCP_RR_CIDR (10.0.1.0/24)│
  │  netns "perouter"         │    │   no VNIs, no tunnelEndpoint... well, they DO use │
  │  VTEP 100.65.0.0/24       │    │   tunnelEndpoint (see "Why route reflectors...")  │
  │  on the underlay NIC      │◄──IPsec Cloud──►                                       │
  │  eBGP-multihop to all 3   │    VPN            worker-a/b/c (EVPN data plane)       │
  │  RRs                      │    │   ipvlan-l3 net1 on br-ex, GCP_VTEP_CIDR (10.0.200.0/24)│
  │  L2VNI 110 ── br-vlan ────┤    │   statically peer all 3 RRs                       │
  └──────────────────────────┼┘    │   L2VNI 110 ── br-hs-110 ── pod                   │
                              │    └──────────────────────────────────────────────────┘
                     workload VLAN
```

- OpenPERouter runs on **every** OpenShift node. The 3 control-plane nodes are
  pure BGP route reflectors (RFC 4456): no L2VNI/L3VNI ever placed on them.
  The 3 workers are the EVPN data plane.
- All GCP nodes share ASN `65001`. Workers statically peer **every** route
  reflector (3 sessions each) instead of a full worker-to-worker mesh, so
  adding a worker costs 3 new sessions instead of N. The reflectors themselves
  do not peer each other -- each independently reflects to/from its own
  worker clients, which is enough since every worker is a client of all 3.
- Route reflection changes the BGP next-hop only for `ipv4-unicast`
  (`next-hop-self`), not for `l2vpn evpn`: EVPN Type-2/3 routes keep the
  originating worker's real VTEP as next-hop, so VXLAN data traffic goes
  **directly** worker-to-worker (or worker-to-VNF); the reflectors only carry
  control-plane traffic.
- On-prem VNF ASN `64514`, VTEP pool `100.65.0.0/24`. It peers all 3 GCP route
  reflectors over the VPN with eBGP-multihop, the same pattern as the workers.
- One **disconnected L2VNI** (`vni 110`) is stretched across every worker and
  the VNF: a pod on `br-hs-110` on the GCP side, a workload VLAN bridged into
  `br-vlan` on the VNF side. Pure east-west L2, no gateway.

### Why route reflectors also use `tunnelEndpoint`

A route reflector has no VNIs and does not need a VXLAN source address, but it
still needs *some* real address to run BGP from, and it still needs the same
ipvlan-L3 CNIDevice as the workers (GCP rejects extra source MACs, ruling out
macvlan). `tunnelEndpoint.interfaceName` is a generic "derive a per-node
address from this pool and place it on this CNIDevice" mechanism; it does not
require the underlay to host any VNI. Reusing it for the reflectors' own
`GCP_RR_CIDR` pool means their addresses are derived automatically from each
node's real index, exactly like the workers' VTEPs, instead of hand-rolling a
second literal-per-node addressing scheme. See `gcp/underlay.sh` for the two
resulting Underlay CRs (`route-reflectors`, `workers`).

## Layout

```
vnf/                     on-prem VNF (systemd/Podman, static config, no k8s)
  quadlets/              routerpod + frr + reloader + vpn sidecar + controller + volume
  Dockerfile.vpn         strongSwan sidecar image
  config/                node-config.yaml + configs/openpe_config.yaml (static)
  frrconfig/             FRR seed files
  start-vpn.sh           strongSwan config + load (runs in perouter netns)
  vlan-setup.sh          create br-vlan + VLAN subinterface (workload side)
  deploy.sh/undeploy.sh  install/remove quadlets and static config
  verify.sh              VPN/BGP/EVPN/datapath checks
gcp/                     GCP OpenShift side (OpenPERouter in Kubernetes mode)
  network.env            addressing + VPN parameters
  env.sh                 discovers infra ID / master+worker nodes / subnets
  vtep.sh                derives a node's tunnel endpoint address from its
                         real openpe.io/nodeindex annotation (both roles)
  openshift/install.sh   Helm-install OpenPERouter (all nodes) + SCCs
  underlay.sh            2 Underlays: route-reflectors (control-plane) + workers
  firewall.sh            intra-cluster BGP+VXLAN firewall rule (see gotcha below)
  alias-ip.sh            register every node's derived address as an alias IP
  setup-cloudvpn.sh      Classic Cloud VPN to the laptop + route + firewall
  l2vni.yaml             stretched L2VNI (workers only) + NAD + workload pod
kubeconfig.sh            pull the cluster kubeconfig from the Jenkins artifact
```

## Prerequisites

- **On-prem (laptop):** Podman + systemd, root, a **spare NIC** for the underlay
  (moved into the router netns, unusable by the host afterwards) and a NIC for
  the workload VLAN. A public IP reachable by GCP for the VPN.
- **GCP:** an OpenShift cluster (this PoC targets `ellorent-vlan-evpn`, CNV
  4.22, 3 masters + 3 workers), `oc` with its kubeconfig, and `gcloud`
  authenticated to the project (`gcloud auth login`, or a valid
  `gcloud auth application-default login` token -- every script here also
  accepts `CLOUDSDK_AUTH_ACCESS_TOKEN` for non-interactive use). The project
  is shared, so every GCP resource this example creates is scoped to the
  cluster infra ID.
- No persistent storage / VMs are required -- the workload is a plain pod.

## Run

Fill in the VPN parameters in `gcp/network.env` (`SHARED_SECRET`, and after the
VPN is created, `GCP_VPN_IP`), and set the underlay/VLAN NIC names.

### 1. GCP side

```bash
export KUBECONFIG=$(find $PWD/../../../cluster-dirs -path '*/auth/kubeconfig')   # or ./kubeconfig.sh <jenkins-build-url>
cd gcp
source network.env                 # SHARED_SECRET, ONPREM_PUBLIC_IP (or autodetected)
./openshift/install.sh             # OpenPERouter on every node
./firewall.sh                      # intra-cluster BGP+VXLAN (see gotcha below)
./underlay.sh                      # route-reflectors (control-plane) + workers Underlays
./alias-ip.sh                      # register every derived address as an alias IP
./setup-cloudvpn.sh                # Cloud VPN to the laptop -> prints GCP_VPN_IP
oc apply -f l2vni.yaml             # stretched L2VNI (workers) + NAD + workload pod
```

Put the printed `GCP_VPN_IP` into `network.env`. `underlay.sh` and
`alias-ip.sh` read each node's real `openpe.io/nodeindex` annotation, so
`install.sh` (or at least the controller being up) must run first.

### 2. On-prem VNF (laptop, as root)

Edit `vnf/config/configs/openpe_config.yaml`: set the underlay `interfaceName`
to your spare NIC, and replace the 3 placeholder route reflector addresses
with the real ones printed by:

```bash
cd gcp && source env.sh && source vtep.sh
for n in "${MASTER_NODES[@]}"; do vtep_ip_for_node "$n" "$GCP_RR_CIDR"; done
```

Then:

```bash
cd vnf
VLAN_NIC=eth2 VLAN_ID=100 ./vlan-setup.sh                 # workload VLAN bridge
NETWORK_ENV=../gcp/network.env sudo ./deploy.sh           # build + start the VNF
sudo ./verify.sh                                          # VPN/BGP/EVPN checks
```

### 3. Test the stretch

- GCP pod `vlan-workload` gets an address from `192.168.100.0/24` on the NAD.
- Give an on-prem host on the VLAN an address in the same subnet and ping the
  pod (and vice-versa). Traffic flows: on-prem host -> `br-vlan` -> VNF L2VNI
  -> VXLAN over VPN -> GCP `br-hs-110` -> pod.
- Verified on the GCP side alone: two pods on different workers
  (`vlan-workload` / a second pod pinned to another node) ping each other with
  0% loss once `firewall.sh` has been applied.

## Teardown

```bash
# on-prem
sudo ./vnf/undeploy.sh
# GCP
oc delete -f gcp/l2vni.yaml
oc delete underlay -n openperouter-system route-reflectors workers
helm uninstall openperouter -n openperouter-system
oc delete namespace openperouter-system
# remove the alias IPs, the vtep-underlay/vpn firewall rules, and the Cloud
# VPN resources created by alias-ip.sh/firewall.sh/setup-cloudvpn.sh with
# gcloud -- everything is named with the ${CLUSTER_INFRA_ID} prefix.
```

## Notes and gotchas

- **GCP firewall: alias-IP-sourced traffic needs a CIDR-based rule, not a
  tag-based one.** The OpenShift installer's own `*-internal-cluster` rule
  *looks* like it should cover the EVPN underlay: it matches by source/target
  instance **tags** (worker, control-plane) and already allows `udp:4789`
  (VXLAN) and, once GCP is configured, would seem to need nothing more for
  BGP. In practice, GCP does **not** reliably attribute tag-based rules to
  traffic sourced from an instance's **alias IP** (the VTEP and route
  reflector addresses are alias IPs, never the instance's primary IP) the way
  it does for the primary IP. The symptom is confusing: ICMP between VTEPs
  works fine (matched by the separate `*-internal-network` CIDR-based rule,
  source `10.0.0.0/16`), which makes the underlay look healthy, while BGP
  (`tcp:179`) and VXLAN (`udp:4789`) both silently fail with 100% loss and
  zero packets ever arriving at the destination (confirmed by comparing
  interface counters on both ends and with a raw `nc -u` test). `firewall.sh`
  works around this with its own **CIDR-based** `source-ranges` rule (not
  `--target-tags`) for exactly `GCP_VTEP_CIDR` and `GCP_RR_CIDR`. The original
  GCP PoC hit and worked around the same issue independently (see
  `../hybrid/gcp/setup.sh`'s own `*-openperouter-network` firewall rule
  upstream, also CIDR-based). Run `firewall.sh` **before** trusting any BGP or
  EVPN state -- without it, BGP sessions simply never establish, with no
  useful error beyond "Connect" state forever.
- **Static / cluster-less:** the VNF controller runs in `--mode host` and reads
  only `node-config.yaml` + `configs/openpe_*.yaml`. With no Kubernetes API it
  logs *"continue with static config only"* and keeps the datapath reconciled
  -- this is expected, not an error.
- **strongSwan sidecar:** the VPN runs in the router pod's `perouter` netns
  (`Pod=routerpod.pod`) so the tunnel, the VTEP and BGP share one routing
  table. The upstream `openperouter/router` image is untouched.
- **Deterministic addresses, but not positionally:** every node's tunnel
  endpoint address is derived from its pool and its **real**
  `openpe.io/nodeindex` annotation, which is *not* allocated in any
  predictable node-sorted order (in one run, the 3 masters got indices 4, 5
  and 0, interleaved with the workers' 1, 2, 3). Never assume "the Nth node
  (sorted by name) gets the Nth address" -- always read the annotation, which
  is exactly what `vtep_ip_for_node` in `vtep.sh` does, uniformly for both
  route reflectors and workers.
- **Shared project:** every `gcloud` call is scoped to the cluster infra ID; do
  not loosen the filters -- other clusters share `ocpstrat-1278`.
