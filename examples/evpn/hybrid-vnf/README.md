# Hybrid VNF: VLAN L2 stretch to a GCP EVPN fabric

This example stretches a Layer 2 VLAN from an on-premises **VNF** (a single
OpenPERouter instance running as a systemd/Podman service, **no Kubernetes**)
to a GCP OpenShift cluster running OpenPERouter, over an IPsec Cloud VPN, using
EVPN/VXLAN.

It is the cloud-VPN, single-VNF variant of [`../hybrid`](../hybrid): the
on-prem side is not a Kubernetes cluster but one container-based router that
also terminates the VPN, so you can exercise the cloud-VPN overhead and the
VLAN attachment without a second cluster.

**Status: fully verified working end-to-end, laptop to GCP**, including the
actual stretched workload: IPsec tunnel established; all 3 on-prem-to-RR
eBGP sessions up (`ipv4-unicast` + `l2vpn evpn`); EVPN Type-3 (VTEP) routes
for all 3 GCP worker VTEPs visible on-prem via route reflection across the
eBGP boundary; the on-prem VXLAN device came up with all 3 worker VTEPs as
head-end-replication flood targets; and a real on-prem workload pinged the
GCP pod bidirectionally with 0% loss (~100ms RTT, matching the VPN's own
latency), with genuine EVPN Type-2 (MAC) routes exchanged in both
directions -- not just VXLAN flood-and-learn.

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
  underlay-setup.sh      create the macvlan underlay uplink (router side)
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

- **On-prem (laptop):** Podman + systemd, root, and a NIC for the workload
  VLAN. For the underlay uplink (moved into the router netns, unusable
  outside it afterwards), either a spare/dedicated NIC, or -- recommended,
  and what was actually used for the verified run below -- a **macvlan
  sub-interface** on the laptop's real uplink via `underlay-setup.sh`, so the
  physical NIC and its own address are never touched. A public IP reachable
  by GCP for the VPN (behind NAT is fine; see the NAT gotcha below).
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
(default `macvlan0`, matching `underlay-setup.sh` below) and replace the 3
route reflector addresses (checked in from a past run, and specific to that
cluster instance/rebuild) with the real ones for your cluster, printed by:

```bash
cd gcp && source env.sh && source network.env && source vtep.sh
for n in "${MASTER_NODES[@]}"; do vtep_ip_for_node "$n" "$GCP_RR_CIDR"; done
```

Then, from `vnf/`:

```bash
# Underlay uplink: a macvlan sub-interface on the real uplink NIC, not the
# NIC itself (see "Prerequisites"). Must exist with a real address BEFORE
# deploy.sh runs -- NetworkDevice only moves an interface and restores
# whatever address it already had, it never assigns one itself.
UNDERLAY_NIC=<real-uplink> UNDERLAY_IP=<free-LAN-ip>/<prefix> \
  UNDERLAY_GW=<LAN-gateway> ./underlay-setup.sh

VLAN_NIC=eth2 VLAN_ID=100 ./vlan-setup.sh                 # workload VLAN bridge

# SKIP_VPN_IMAGE_BUILD=1 if rootful `podman build` on this host cannot reach
# the internet (see gotcha below) and you already loaded the image rootless.
NETWORK_ENV=../gcp/network.env sudo -E ./deploy.sh        # start the VNF

# The move into perouter preserves the uplink's address but not a default
# route -- add one once perouter exists (deploy.sh has run):
sudo ip netns exec perouter ip route add default via <LAN-gateway> dev macvlan0

sudo ./verify.sh                                          # VPN/BGP/EVPN checks
```

At this point `verify.sh` should show the IPsec SA `ESTABLISHED`, all 3 route
reflectors `Established` in both `show bgp summary` address families, and
EVPN Type-3 routes for all 3 GCP worker VTEPs under `show bgp l2vpn evpn`.
`show evpn vni 110` reporting "VNI 110 does not exist" at this stage is
expected -- the L2VNI only attaches once `vlan-setup.sh`'s `br-vlan` exists,
which the commands above already create; if this step ran before `br-vlan`
existed, restart it once via `sudo systemctl restart
controllerpod-pod.service` (not `podman restart controller` directly --
quadlet-managed pods track state through the systemd unit, and bypassing it
can leave the unit thinking the pod is down even though podman restarted it
fine) to force a fresh reconcile.

### 3. Test the stretch

GCP pod `vlan-workload` gets an address from `192.168.100.0/24` on the NAD
(`192.168.100.10` in the verified run). Give an on-prem host on the VLAN an
address in the same subnet (avoid `.10`-`.100`, the GCP NAD's whereabouts
range) and ping the pod (and vice-versa). Traffic flows: on-prem host ->
`br-vlan` -> VNF L2VNI -> VXLAN over VPN -> GCP `br-hs-110` -> pod.

Without a real VLAN-trunked switch port handy, `vlan-setup.sh`'s `VLAN_NIC`
can be a plain dummy interface -- only `br-vlan` existing and having a member
matters for the controller, nothing here needs the VLAN tag to actually
carry traffic anywhere:

```bash
sudo ip link add dummy-wl type dummy && sudo ip link set dummy-wl up
sudo VLAN_NIC=dummy-wl VLAN_ID=100 ./vlan-setup.sh

# force a reconcile so the controller attaches L2VNI 110 to the now-existing
# br-vlan (see the "controller restart" note in step 2) -- do this via
# systemctl, not `podman restart controller` directly: quadlet-managed pods
# track state through the unit, and bypassing it can leave the unit thinking
# the pod is down even though podman restarted it fine.
sudo systemctl restart controllerpod-pod.service

# a netns + veth pair into br-vlan stands in for a real on-prem host on the
# VLAN:
sudo ip netns add onprem-workload
sudo ip link add veth-host type veth peer name veth-ns
sudo ip link set veth-host master br-vlan up
sudo ip link set veth-ns netns onprem-workload
sudo ip netns exec onprem-workload ip link set lo up
sudo ip netns exec onprem-workload ip link set veth-ns up
sudo ip netns exec onprem-workload ip addr add 192.168.100.200/24 dev veth-ns

sudo ip netns exec onprem-workload ping -c 5 192.168.100.10
```

**Verified working, bidirectionally, 0% loss, ~100ms RTT** (on-prem laptop to
`ellorent-vlan-evpn-k25qm`):
- `show evpn vni 110` on-prem: VXLAN device up, all 3 GCP worker VTEPs
  (`10.0.200.1/2/3`) as head-end-replication flood targets.
- `show evpn mac vni 110` on-prem, after the ping: the GCP pod's real MAC
  learned as `remote` via VTEP `10.0.200.1` -- a genuine EVPN Type-2 route,
  not flood-and-learn.
- The same `show evpn mac vni 110` on GCP's worker-a router pod: the on-prem
  test workload's MAC learned as `remote` via VTEP `100.65.0.0` -- confirming
  Type-2 routes flow both ways across the tunnel.

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
- **Home router NAT can silently break the on-prem VPN.** Observed on at
  least one dev laptop: when the VPN sidecar's outbound traffic passes
  through an *extra* NAT layer on top of the home router's own NAT --
  reproduced identically with podman rootless (`pasta`), podman rootful
  (`netavark` bridge), and plain Docker's default bridge -- GCP's tunnel sits
  at `NO_INCOMING_PACKETS` forever: IKE packets leave the container fine
  (confirmed with `tcpdump`) but never elicit a response, while the identical
  packet from a single-NAT-hop path (a raw host socket, or `--network host`)
  gets an immediate, valid IKE response. This looks like a common consumer
  router firmware bug around "IPsec/VPN passthrough" ALG handling of
  doubly-NATed traffic, not anything specific to this example. `perouter`'s
  `NetworkDevice` uplink is already a single NAT hop once it is a real or
  macvlan interface (see `underlay-setup.sh` and "Prerequisites") -- the
  failure mode only shows up if you instead try to give the VPN container its
  own ordinary container-engine network (podman/Docker default bridge) for
  its uplink.
- **MTU: VXLAN and IPsec overhead both need accounting for, and not the
  same way on each side.** OpenPERouter automatically sizes the L2VNI's
  veth pair as (underlay interface's own MTU) − 50 (VXLAN overhead) -- it
  reads the underlay interface's MTU but never writes it, so shrinking that
  interface is the correct, reconcile-safe way to also account for
  encapsulation the controller cannot see, like a VPN sitting underneath.
  But this tunnel has an on-prem-specific complication: **do this on GCP's
  `net1`, never on the on-prem `NetworkDevice` uplink.** On GCP the worker
  VM's own kernel never does IPsec (the Cloud VPN gateway terminates it
  entirely), so `net1` only ever carries plain VXLAN and shrinking it is
  safe (`gcp/underlay.sh`'s `mtu: 1430`). On-prem, that same interface is
  *also* the interface strongSwan's ESP output must physically fit through,
  since perouter's netns is shared between FRR/VXLAN and the VPN sidecar --
  shrinking it there starves ESP's own transmission budget instead of
  correctly sizing the VXLAN payload, producing a *smaller* effective MTU
  than intended (concretely measured: 1316 instead of the intended 1380,
  when this mistake was made and then corrected during this PoC). The
  on-prem side instead relies on the kernel's own dynamic path-MTU
  discovery (already handled transparently by XFRM's ESP output path) to
  protect oversized packets, and it already does, correctly, with the
  interface at its normal, undiminished MTU.
  - There is a second, unrelated gap: a pod's NAD-created interface (here,
    `net1` via the bridge CNI plugin) is a completely separate veth pair
    from OpenPERouter's own, entirely outside its reconcile loop, so it
    keeps whatever MTU the NAD gives it (1500 by default) regardless of
    what the rest of the L2 segment uses. Since one L2 broadcast domain
    needs one uniform MTU (a GCP pod and the on-prem VNF can each send
    frames to the other, not just receive them), this needs its own
    explicit `"mtu": 1380` in the NAD config (`gcp/l2vni.yaml`) -- without
    it, a pod is a live PMTU black-hole risk, not merely a cosmetic mismatch.
  - **How 1380 was measured**: `ping -M do -s N` (or, since some `ping`
    builds -- e.g. BusyBox in the test images used here -- don't support
    `-M do`, any plain oversized `ping`) from a real workload on one side to
    the other, increasing `N` until replies stop / a `Frag needed ... mtu =
    M` ICMP appears; a `ping -s N` payload corresponds to an IP-layer size
    of `N+28` (20-byte IP + 8-byte ICMP header). 1380 (IP-layer) was the
    largest size that worked reliably, symmetric in both directions, for
    this specific tunnel (AES-GCM-256, ESP-in-UDP/NAT-T) over this
    laptop's physical path -- both the target number and which side can
    safely apply it statically are specific to this setup; re-measure
    rather than assuming they carry over to a different cipher suite,
    network path, or an architecture where the VPN does *not* share a
    netns with the VXLAN underlay.
- **`local_addrs = %defaultroute` silently fails under swanctl/vici.**
  `%defaultroute` is a legacy `ipsec.conf`/`starter` keyword; loaded via
  `swanctl --load-all` it is not recognized, and charon tries to literally
  DNS-resolve the string ("Name does not resolve"), binds to `0.0.0.0`, and
  the peer never sees a plausible source address. `start-vpn.sh` uses `%any`
  (the swanctl.conf equivalent: let charon pick the source address via
  routing to `remote_addrs`).
- **Rootful `podman build` may not reach the internet** on hosts where
  rootless build works fine (observed with the netavark rootful network
  backend on at least one dev machine) -- `podman pull`/`run` are unaffected,
  only the build step. Build `Dockerfile.vpn` rootless and load it into
  root's storage (`podman save` / `sudo podman load`), then
  `SKIP_VPN_IMAGE_BUILD=1 sudo -E ./deploy.sh`.
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
