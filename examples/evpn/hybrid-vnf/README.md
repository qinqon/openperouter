# Hybrid VNF: VLAN L2 stretch to a GCP EVPN fabric

This example stretches a Layer 2 VLAN from an on-premises **VNF** (a single
OpenPERouter instance running as a systemd/Podman service, **no Kubernetes**)
to a GCP OpenShift cluster running OpenPERouter, over an IPsec Cloud VPN, using
EVPN/VXLAN.

It is the cloud-VPN, single-VNF variant of [`../hybrid`](../hybrid): the
on-prem side is not a Kubernetes cluster but one container-based router that
also terminates the VPN, so you can exercise the cloud-VPN overhead and the
VLAN attachment without a second cluster.

Both ends run in a **VM**: the on-prem VNF in a dedicated libvirt VM
(`vm-router`), the on-prem workload in a second one (`vm-workload`), and the
GCP-side workload as a **KubeVirt** `VirtualMachine` -- matching the actual
scenario this example is meant to de-risk, migrating a VM's network
attachment. The two on-prem VMs are provisioned and fully configured with
**no manual SSH steps** via [kcli](https://kcli.readthedocs.io) + cloud-init
-- see "On-prem VM provisioning" below.

**Status: verified working end-to-end, laptop to GCP**, for everything this
example is responsible for, including genuine **workload-to-workload**
connectivity between the two VM endpoints (`vm-workload` on-prem, the
KubeVirt VM on GCP) and genuine 802.1Q VLAN tag handling: IPsec tunnel
established; all 3 on-prem-to-RR eBGP sessions up (`ipv4-unicast` +
`l2vpn evpn`); EVPN Type-3 (VTEP) routes for all 3 GCP worker VTEPs
visible on-prem via route reflection across the eBGP boundary; the
on-prem VXLAN device came up with all 3 worker VTEPs as
head-end-replication flood targets; genuine EVPN Type-2 (MAC) routes for
each workload VM's real MAC exchanged in both directions (not just VXLAN
flood-and-learn); MTU correctly accounted for on both sides (see the MTU
gotcha); and bidirectional 300KB TCP transfers directly between the two
workload VMs completed with 0 bytes lost (MD5-verified) at realistic,
everyday-file-size scale, not just small pings.

`sim-switch-setup.sh` builds a genuine VLAN-aware Linux bridge as a
simulated switch (a real trunk port carrying tagged frames to the VNF, a
real access port carrying plain untagged frames to the on-prem workload),
so the same kernel 802.1Q code a physical switch and NIC would use is
genuinely exercised -- confirmed directly with `tcpdump`: identical ICMP
exchanges show `vlan 100` tags on the trunk port and no tag at all on the
access port. Both switch ports carry a **real VM's** traffic (libvirt
taps into `vm-router`/`vm-workload`) -- see "Test the stretch" below for
the full setup and results. What remains unverified is only physical
hardware itself (a real NIC/driver and a real switch), which is a much
smaller, lower-risk gap than the VLAN-tagging mechanics are.

```
--- DIAGRAM 1: on-prem -- two libvirt VMs + a simulated VLAN switch ---

+--------------+              +----------------+              +--------------+
| vm-workload  |              | sw-access-port |              |  vm-router   |
|    enp2s0    |              |   (untagged,   |              |    enp3s0    |
|   .200/24    |              |   PVID 100)    |              |  enp3s0.100  |
|  (plain, no  | -- plain --> |                | vlan 100 --> | (strips the  |
| VLAN aware-  |              | sw-trunk-port  |              | 802.1Q tag)  |
| ness at all) |              |    (tagged,    |              +--------------+
+--------------+              |   vlan 100)    |
                              +----------------+

                              (sim-switch bridge: real VM taps, not test
                               veth pairs -- vnetN <-> access port,
                               vnetM <-> trunk port)

                                                                      |
                                                                      v
                                                                +----------+
                                                                | br-vlan  |
                                                                | mtu 1450 |
                                                                +----------+

         |
         v
+----------------------------------------------------------------------+
| netns "perouter" (FRR + strongSwan + VXLAN share one routing table)  |
|                                                                      |
| +------------+    +----------+    +-----------+    +----------+      |
| | host-e-110 |----|  vni110  |----| br-pe-110 |----| pe-e-110 |      |
| +------------+    | (VXLAN,  |    +-----------+    +----------+      |
|                   | vni 110) |                                       |
|                   +----------+                                       |
| ^ all 4 above: mtu 1450 (auto-derived: enp2s0 mtu 1500 - 50 VXLAN)   |
|                                                                      |
|                         |                                            |
|                         v                                            |
|                 +---------------+                                    |
|                 |       lo      |                                    |
|                 | 100.65.0.0/32 |                                    |
|                 +---------------+                                    |
|                                                                      |
| +----------+   +-------------+   +----------------+                  |
| |   FRR    |---|  strongSwan |---|     enp2s0     |                  |
| | AS 64514 |   | (IPsec/VPN) |   |   (underlay    |                  |
| +----------+   +-------------+   |     uplink)    |                  |
|                                  |    mtu 1500    |                  |
|                                  | (kept full --  |                  |
|                                  |  NOT reduced,  |                  |
|                                  |  see MTU note) |                  |
|                                  +----------------+                  |
+----------------------------------------------------------------------+

The whole "netns perouter" box above runs inside vm-router. enp2s0 is a
macvtap interface (bridge mode) on the laptop's real physical uplink NIC,
giving the VM a genuine single-NAT-hop LAN presence -- the same property
the bare-host "macvlan0 sub-interface" trick has (see
config/configs/openpe_config.yaml), but without needing that trick at all:
a VM's NIC is never shared with a management interface the way a bare
laptop's single physical NIC is.

--- DIAGRAM 2: cross-cloud -- on-prem VNF <-> GCP over the VPN ---

+-------------------+                +-----------------------+
|        FRR        |-- IPsec/VPN -->|   Cloud VPN Gateway   |
|      AS 64514     |                |     35.222.55.173     |
|  VTEP 100.65.0.0  |                | terminates IPsec here |
| underlay mtu 1500 |                |    (+ESP overhead)    |
+-------------------+                +-----------------------+

                                                 VPC route
                                                 |
                                                 v
                                 +-------------------------------+
                                 |          master-0/1/2         |
                                 |   route reflectors, AS 65001  |
                                 |    GCP_RR_CIDR 10.0.1.0/24    |
                                 | ipvlan net1: mtu 1430, no VNI |
                                 +-------------------------------+

iBGP route reflection
(ipv4-unicast + evpn)
                                                 |
                                                 v
                         +----------------------------------------------+
                         |                 worker-a/b/c                 |
                         |          EVPN data plane, AS 65001           |
                         |         GCP_VTEP_CIDR 10.0.200.0/24          |
                         |            ipvlan net1: mtu 1430             |
                         |   veth/br-hs-110: mtu 1380 (auto: 1430-50)   |
                         |     NAD: mtu 1380 (explicit, unmanaged)      |
                         | KubeVirt VM vlan-workload-vm 192.168.100.10  |
                         +----------------------------------------------+

Logical BGP/EVPN relationships (both ride over the IPsec tunnel + VPC
route shown in diagram 2, not separate physical links):
  - on-prem VNF (AS 64514) <--eBGP-multihop(ttl 10)--> route reflectors (AS 65001)
  - on-prem VNF (AS 64514) <----EVPN VXLAN data plane (direct)----> workers
    route reflection rewrites the ipv4-unicast next-hop, never the EVPN
    next-hop, so VXLAN data-plane traffic never actually transits the RRs

Shared L2 segment: L2VNI 110, subnet 192.168.100.0/24
  vm-workload <-802.1Q-> sim-switch <-untag-> enp3s0.100 <-> br-vlan <-> perouter
      <--IPsec/VPN--> Cloud VPN GW --VPC--> worker VTEP <-> br-hs-110 <-> vlan-workload-vm

MTU chain -- measured safe end-to-end size: 1380 bytes (IP-layer).
OpenPERouter auto-derives each L2VNI veth as (underlay iface mtu) - 50
(VXLAN overhead); it reads the underlay's mtu but never writes it, so
that interface is the one correct, reconcile-safe place to also account
for IPsec -- but ONLY where that interface does not itself carry IPsec:

  GCP (static fix, safe):  net1 mtu 1430 --auto--> veth/VM mtu 1380
    worker VM's kernel never does IPsec (Cloud VPN gateway terminates
    it), so net1 only ever carries plain VXLAN -- shrinking it is safe.
    The NAD's own interface is a separate, OpenPERouter-unmanaged veth
    and needs its OWN explicit mtu 1380, or it silently keeps 1500.

  on-prem (dynamic, NOT a static fix): enp2s0 mtu 1500 (unchanged)
    --auto--> veth/br-vlan mtu 1450 (VXLAN-only aware)
    enp2s0 is ALSO the interface strongSwan's ESP output must fit
    through (perouter's netns is shared by VXLAN and the VPN sidecar).
    Shrinking it double-counts IPsec overhead and starves ESP's own
    transmission budget -- tried and measured making this WORSE (1316
    instead of 1380), not better. The 1450->1380 gap here is instead
    closed by the kernel's own dynamic path-MTU discovery (ICMP
    'Frag needed', already handled transparently by XFRM), which is
    what was actually measured working correctly end-to-end.
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
                         -- runs inside the vm-router libvirt VM
  quadlets/              routerpod + frr + reloader + vpn sidecar + controller + volume
  Dockerfile.vpn         strongSwan sidecar image
  config/                node-config.yaml + configs/openpe_config.yaml (static)
  frrconfig/             FRR seed files
  start-vpn.sh           strongSwan config + load (runs in perouter netns)
  vlan-setup.sh          create br-vlan + VLAN subinterface (workload side)
  add-underlay-route.sh  add perouter's default route once the underlay
                         interface is moved in (waits for the controller's
                         async move; see deploy.sh/network.env)
  libvirt-host-setup.sh  fix Docker's iptables FORWARD policy silently
                         blocking libvirt NAT traffic (needed for
                         vm-router's/vm-workload's mgmt NIC to reach the
                         internet at all)
  sim-switch-setup.sh    build the VLAN-aware Linux bridge ("sim-switch")
                         that vm-router's/vm-workload's sim-switch NICs
                         attach to -- a real trunk port carrying tagged
                         frames to vm-router, a real access port carrying
                         plain untagged frames to vm-workload
  underlay-setup.sh      ALTERNATIVE to the VM approach: create a macvlan
                         underlay uplink directly on a bare host (no
                         libvirt) -- see "On-prem: bare host" below
  vms/                   kcli + cloud-init: provisions vm-router and
                         vm-workload with no manual SSH steps
    kcli-plan.yml        defines both VMs (nets, disks, cloud-init)
    vm-router-init.sh    cloud-init script: packages, SELinux workaround,
                         clones this repo, runs vlan-setup.sh + deploy.sh
                         + add-underlay-route.sh -- all automatic
    fix-vlan-membership.sh
                         set each VM's sim-switch tap to the correct VLAN
                         (kcli/libvirt has no concept of sim-switch's own
                         VLAN filtering) -- run once, right after
                         `kcli create plan`
    secrets.yml.sample   template for the gitignored secrets.yml paramfile
                         (SHARED_SECRET/GCP_VPN_IP -- never committed)
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
  l2vni.yaml             stretched L2VNI (workers only) + NAD
  vm-workload.yaml       KubeVirt VirtualMachine on the L2VNI (the actual
                         workload; l2vni.yaml only sets up its network)
kubeconfig.sh            pull the cluster kubeconfig from the Jenkins artifact
```

## Prerequisites

- **On-prem (laptop):** libvirt/KVM and [kcli](https://kcli.readthedocs.io)
  (`sudo dnf -y copr enable karmab/kcli && sudo dnf -y install kcli`; run
  kcli itself as a user in the `libvirt`/`qemu` groups, not via `sudo` --
  see kcli's own "Libvirt additional configuration" docs and
  `vnf/vms/kcli-plan.yml`'s header comment). A downloaded Fedora Cloud image
  (`kcli download image fedora44`). A public IP reachable by GCP for the VPN
  (behind NAT is fine; see the NAT gotcha below) -- this is the laptop's
  own uplink, used by `vm-router` via a macvtap NIC, not anything you set
  up yourself.
  - **Alternative, no libvirt/VMs at all:** the VNF can still run directly
    on the bare laptop via Podman + systemd -- see "On-prem: bare host"
    under Run below. Everything else in this README (GCP side, gotchas,
    MTU chain, VLAN tagging) is identical either way; only how the on-prem
    side is hosted differs.
- **GCP:** an OpenShift cluster (this PoC targets `ellorent-vlan-evpn`, CNV
  4.22, 3 masters + 3 workers) with **OpenShift Virtualization (CNV)
  installed** (for the `vlan-workload-vm` KubeVirt VM), `oc` with its
  kubeconfig, and `gcloud` authenticated to the project (`gcloud auth
  login`, or a valid `gcloud auth application-default login` token -- every
  script here also accepts `CLOUDSDK_AUTH_ACCESS_TOKEN` for non-interactive
  use). The project is shared, so every GCP resource this example creates
  is scoped to the cluster infra ID.

## Run

Fill in the VPN parameters in `gcp/network.env` (`SHARED_SECRET`, and after the
VPN is created, `GCP_VPN_IP`).

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
oc apply -f l2vni.yaml             # stretched L2VNI (workers) + NAD
oc apply -f vm-workload.yaml       # KubeVirt VM workload on that NAD
```

Put the printed `GCP_VPN_IP` into `network.env`. `underlay.sh` and
`alias-ip.sh` read each node's real `openpe.io/nodeindex` annotation, so
`install.sh` (or at least the controller being up) must run first.

### 2. On-prem VM provisioning

Edit `vnf/config/configs/openpe_config.yaml`: replace the 3 route reflector
addresses (checked in from a past run, and specific to that cluster
instance/rebuild) with the real ones for your cluster, printed by:

```bash
cd gcp && source env.sh && source network.env && source vtep.sh
for n in "${MASTER_NODES[@]}"; do vtep_ip_for_node "$n" "$GCP_RR_CIDR"; done
```

Then, from `vnf/`:

```bash
# One-time host prerequisites (idempotent, safe to rerun):
sudo UPLINK_NIC=<real-uplink> ./libvirt-host-setup.sh   # Docker/libvirt fix
sudo ./sim-switch-setup.sh                              # VLAN-aware bridge

cd vms
cp secrets.yml.sample secrets.yml    # fill in SHARED_SECRET, GCP_VPN_IP
                                      # (gitignored -- never commit this file)

# Provisions vm-router and vm-workload. Run as a user in the "libvirt"/
# "qemu" groups, not via sudo -- see kcli-plan.yml's own header comment.
kcli create plan -f kcli-plan.yml \
  -P uplink_nic=<real-uplink> -P uplink_ip=<free-LAN-ip> \
  -P uplink_gw=<LAN-gateway> --paramfile secrets.yml \
  hybrid-vnf-onprem

./fix-vlan-membership.sh   # required -- see the script's own header comment
```

That's it: cloud-init inside `vm-router` handles everything else
automatically -- package installs, the SELinux workaround, cloning this
repo, `vlan-setup.sh`, `deploy.sh`, and `add-underlay-route.sh` -- with no
manual SSH steps. It takes a couple of minutes (a base-image systemd
upgrade plus the VPN sidecar image build/pull); watch progress with:

```bash
ssh fedora@$(sudo virsh domifaddr vm-router | awk '/ipv4/{print $4}' | cut -d/ -f1) \
  'sudo cloud-init status --wait; sudo tail -20 /var/log/vm-router-init.log'
```

Then, from inside `vm-router` (or via the same `ssh` prefix):

```bash
sudo ./verify.sh   # VPN/BGP/EVPN checks (repo path: ~/openperouter/examples/evpn/hybrid-vnf/vnf)
```

`verify.sh` should show the IPsec SA `ESTABLISHED`, all 3 route reflectors
`Established` in both `show bgp summary` address families, and EVPN Type-3
routes for all 3 GCP worker VTEPs under `show bgp l2vpn evpn`. If BGP looks
healthy but `show evpn vni 110` reports "VNI 110 does not exist", force a
fresh reconcile with `sudo systemctl restart controllerpod-pod.service`
(not `podman restart controller` directly -- quadlet-managed pods track
state through the systemd unit, and bypassing it can leave the unit
thinking the pod is down even though podman restarted it fine).

#### On-prem: bare host

The VNF can also run directly on a bare host (Podman + systemd, root, no
libvirt/VMs at all) instead of inside `vm-router` -- useful if you don't
want to set up libvirt, or don't have a spare machine for it. Everything
else in this README is identical either way.

```bash
# Underlay uplink: a macvlan sub-interface on the real uplink NIC, not the
# NIC itself. Must exist with a real address BEFORE deploy.sh runs --
# NetworkDevice only moves an interface and restores whatever address it
# already had, it never assigns one itself.
UNDERLAY_NIC=<real-uplink> UNDERLAY_IP=<free-LAN-ip>/<prefix> \
  UNDERLAY_GW=<LAN-gateway> ./underlay-setup.sh

VLAN_NIC=eth2 VLAN_ID=100 ./vlan-setup.sh                 # workload VLAN bridge
```

Edit `vnf/config/configs/openpe_config.yaml`'s underlay `interfaceName` to
`macvlan0` (see its own comment for why a VM's real NIC needs no such
trick, but a bare host with one shared uplink does), then:

```bash
# SKIP_VPN_IMAGE_BUILD=1 if rootful `podman build` on this host cannot reach
# the internet (see gotcha below) and you already loaded the image rootless.
NETWORK_ENV=../gcp/network.env sudo -E ./deploy.sh        # start the VNF

./add-underlay-route.sh   # add perouter's default route (waits for the
                           # controller's async interface move); or set
                           # UNDERLAY_IFACE/UNDERLAY_GW in network.env
                           # beforehand and deploy.sh renders them for you

sudo ./verify.sh                                          # VPN/BGP/EVPN checks
```

### 3. Test the stretch

The GCP KubeVirt VM `vlan-workload-vm` has a static address on
`192.168.100.0/24` set via cloud-init (`192.168.100.10`, see
`gcp/vm-workload.yaml`). `vm-workload` (on-prem) has a static address on the
same subnet (`192.168.100.200`, set by `kcli-plan.yml`'s `workload_ip`
parameter). Traffic flows: `vm-workload` -> `sim-switch` (tags VLAN 100) ->
`vm-router`'s `enp3s0.100` (strips the tag) -> `br-vlan` -> VNF L2VNI ->
VXLAN over VPN -> GCP `br-hs-110` -> `vlan-workload-vm`.

`sim-switch-setup.sh` (already run once as a prerequisite in step 2) builds
a genuine VLAN-aware Linux bridge as the simulated switch: a real trunk
port carrying `vlan-setup.sh`'s tagged VLAN to `vm-router`, a real access
port carrying plain untagged Ethernet to `vm-workload` -- exactly how a
real end-user device connects, since almost no real host runs 8021q
itself. This is not a stand-in for tagging: the switch bridge's VLAN
filtering is the same kernel code a real switch ASIC/software switch uses,
`vlan-setup.sh`'s `.100` subinterface on the trunk side does genuine tag
stripping/insertion, and both switch ports carry a **real VM's** traffic
via real libvirt taps.

```bash
VM_ROUTER_IP=$(sudo virsh domifaddr vm-router | awk '/ipv4/{print $4}' | cut -d/ -f1)
VM_WORKLOAD_IP=$(sudo virsh domifaddr vm-workload | awk '/ipv4/{print $4}' | cut -d/ -f1)
ssh fedora@"${VM_WORKLOAD_IP}" ping -c 5 192.168.100.10
```

**Verify the tagging itself is real**, not assumed, by capturing the same
ping on both switch ports at once (find the current tap names with
`sudo virsh domiflist vm-router`/`vm-workload` -- they change across VM
recreations, so look them up fresh each time rather than assuming fixed
names):
```bash
sudo tcpdump -nnei <vm-router's sim-switch tap> icmp &    # expect: vlan 100 tag visible
sudo tcpdump -nnei <vm-workload's sim-switch tap> icmp &  # expect: plain Ethernet, no tag
ssh fedora@"${VM_WORKLOAD_IP}" ping -c 3 192.168.100.10
```
Confirmed: the identical ICMP exchange (same id/seq, same MACs) shows
`ethertype 802.1Q (0x8100)...vlan 100` on the trunk-side tap and plain
`ethertype IPv4` with no tag at all on the access-side tap -- the switch is
genuinely adding/removing the tag, not passing it through untouched.

**Verified working, bidirectionally**, workload VM to workload VM through
this real VLAN path (on-prem laptop to `ellorent-vlan-evpn-k25qm`):
- Ping: 0% loss, ~100ms RTT (matching the VPN's own latency).
- MTU boundary holds exactly as measured (see the MTU gotcha): 1380 bytes
  (IP-layer) 0% loss, 1381 bytes cleanly rejected (`ping -M do -s 1352`/
  `-s 1353` from `vm-workload`) -- confirmed through the real tagged,
  real-VM path.
- `show evpn vni 110` on-prem: VXLAN device up, all 3 GCP worker VTEPs as
  head-end-replication flood targets.
- `show evpn mac vni 110` on-prem, after the ping: `vm-workload`'s **real**
  MAC (its `enp2s0`'s own address, arriving after genuine tag stripping)
  learned as `local`, and `vlan-workload-vm`'s MAC learned as `remote` via
  VTEP `10.0.200.1` -- a genuine EVPN Type-2 route, not flood-and-learn.
- The same MAC table on GCP's worker-a router pod: `vm-workload`'s MAC
  learned as `remote` via VTEP `100.65.0.0` -- confirming Type-2 routes
  flow both ways across the tunnel, originating from a MAC that only ever
  existed behind the simulated access port.
- **Real bulk TCP transfers, both directions**: 300KB of random data via
  plain `nc`, `vlan-workload-vm` to `vm-workload` and back, using
  `virtctl ssh` for the GCP VM (its `nc`/`ncat` is nmap-ncat syntax, not
  BusyBox -- `nc -l 5002`, not `nc -l -p 5002`, for listen mode) and a
  plain `ssh` to `vm-workload`:
  ```bash
  # vlan-workload-vm -> vm-workload (start the receiver first)
  ssh fedora@"${VM_WORKLOAD_IP}" 'nc -l 5002 > received.dat' &
  virtctl ssh fedora@vmi/vlan-workload-vm -n default \
    -c "head -c 307200 /dev/urandom | tee /tmp/sent.dat | nc -N 192.168.100.200 5002"
  # compare: md5sum on both sides
  ```
  Both directions: exactly 307200 bytes received, MD5 identical to what was
  sent -- 0 bytes lost or corrupted across roughly 215 TCP segments per
  transfer, each constrained by the fixed MTU chain end to end, and each
  one genuinely crossing the simulated trunk/access ports with real 802.1Q
  tags added and removed in transit, between two real VMs.

## Teardown

```bash
# on-prem VMs (deletes vm-router and vm-workload; the sim-switch bridge and
# its keepalive port are left as-is -- delete manually if desired:
# sudo ip link delete sim-switch)
cd vnf/vms && kcli delete plan hybrid-vnf-onprem

# on-prem bare host, if you used that path instead
sudo ./vnf/undeploy.sh

# GCP
oc delete -f gcp/vm-workload.yaml
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
  `NetworkDevice` uplink is already a single NAT hop once it is a real,
  macvlan, or (inside `vm-router`) macvtap interface -- the failure mode
  only shows up if you instead try to give the VPN container its own
  ordinary container-engine network (podman/Docker default bridge) for its
  uplink. A VM's macvtap NIC on the physical uplink has exactly the same
  single-NAT-hop property as the bare host's macvlan sub-interface (see
  `underlay-setup.sh`), which is why `vm-router`'s `enp2s0` needs no special
  setup for this beyond `kcli-plan.yml`'s own network definition.
- **Docker silently blocks libvirt NAT traffic on a host running both.**
  Docker sets the classic iptables `filter` table's `FORWARD` chain default
  policy to `DROP` (a deliberate Docker security measure, applied globally,
  independent of firewalld/nftables' own tables). Since libvirt's `virbr0`
  forwarding isn't explicitly permitted by any of Docker's own chains, it
  silently falls through to that `DROP`. Symptom: `vm-router`'s/
  `vm-workload`'s management NIC has **no outbound connectivity at all**
  (not even ICMP) despite routing, `rp_filter`, and firewalld's own zone
  chains all looking correct -- confirmed via `nft monitor trace`: every
  firewalld/libvirt chain shows `policy accept`, then Docker's own
  `ip filter FORWARD`'s `policy drop` is what actually kills the packet.
  This blocks cloud-init's own package installs/image pulls inside
  `vm-router`, so it must be fixed *before* `kcli create plan`.
  `libvirt-host-setup.sh` adds the fix (an explicit `ACCEPT` rule in
  `DOCKER-USER`, the chain Docker reserves for user customizations and
  never overwrites) -- but it does **not** survive a host reboot, so rerun
  it after one.
- **A Fedora Cloud image's `/sys` mountpoint can be mislabeled for
  SELinux**, apparently inherited from however that particular image build
  was produced (observed AVC denial: `mock_var_lib_t` instead of
  `sysfs_t`). Symptom: `routerpod-pod.service`'s `ExecStartPre` (`ip netns
  exec perouter ip link set lo up`) fails with "mount of /sys failed:
  Permission denied" -- but only when launched by systemd (which SELinux
  policy transitions into the more restricted `ifconfig_t` domain for
  `/usr/sbin/ip`), not when run interactively (`unconfined_t` bypasses the
  check), which makes it look like a systemd-specific bug at first. `touch
  /.autorelabel; reboot` does **not** fix it: the mislabel is on the
  mountpoint directory itself, permanently hidden under the live sysfs
  mount once anything is mounted there, so a normal relabel pass never
  reaches it (confirmed: still denied after a full autorelabel). Properly
  fixing the hidden label would mean unmounting `/sys` in an isolated mount
  namespace (`unshare --mount`) to expose and `chcon` the real underlying
  directory -- risky on a live system with `/sys` nested-mounted many times
  over (cgroup, tracefs, configfs, ...). `vm-router-init.sh` instead sets
  SELinux permissive on this disposable VM, which is a pragmatic call for a
  PoC, not something to carry into production without actually fixing the
  label.
- **kcli quirks hit standing this up from scratch** (all worked around in
  `vms/kcli-plan.yml`/`sim-switch-setup.sh`/`fix-vlan-membership.sh` --
  see their own comments for the full detail):
  - A brand-new bridge with no ports has no carrier, and kcli only
    recognizes a bridge as a valid network name if libvirt's interface
    driver considers it "active" -- which, on at least one dev host,
    requires that existing carrier. `sim-switch-setup.sh` adds a tiny,
    permanent keepalive veth pair for exactly this, so `sim-switch` is
    valid from a genuinely from-scratch `kcli create plan`, not just on a
    rerun against an already-populated bridge.
  - kcli defaults to the older i440fx (`pc`) machine type, which gives
    `ensN` predictable interface names inside the guest, not the `enpXsY`
    names this whole example (and a plain `virt-install` VM) assumes.
    `machine: q35` in the plan fixes this.
  - kcli/libvirt's plain `bridge` NIC attachment has no concept of a
    VLAN-filtering bridge's own VLAN membership: a freshly-attached tap
    defaults to untagged VLAN 1, completely isolated from `sim-switch`'s
    real trunk/access ports (`Destination Host Unreachable`, not just
    packet loss, since there is no L2 path at all). `fix-vlan-membership.sh`
    fixes this, run as an explicit step right after `kcli create plan`
    rather than as a kcli `workflow` plan entry -- kcli's own VM creation
    is threaded and workflow entries do not reliably wait for every VM
    thread to have actually finished first.
  - The on-prem VNF's underlay interface move (into the `perouter` netns)
    happens asynchronously inside the controller container's own
    reconciliation loop, not synchronously as part of `routerpod`'s own
    `ExecStartPre` steps. `add-underlay-route.sh` waits for it (up to 2
    minutes) before adding perouter's default route; a naive one-shot
    attempt right after `deploy.sh` reliably fails with "Cannot find
    device" on a genuine from-scratch deploy.
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
  - There is a second, unrelated gap: the NAD-created interface (here,
    `net1` via the bridge CNI plugin -- whatever attaches to it, a pod or,
    now, the `vlan-workload-vm` KubeVirt VM) is a completely separate veth
    pair from OpenPERouter's own, entirely outside its reconcile loop, so
    it keeps whatever MTU the NAD gives it (1500 by default) regardless of
    what the rest of the L2 segment uses. Since one L2 broadcast domain
    needs one uniform MTU (the GCP workload and the on-prem VNF can each
    send frames to the other, not just receive them), this needs its own
    explicit `"mtu": 1380` in the NAD config (`gcp/l2vni.yaml`) -- without
    it, the workload is a live PMTU black-hole risk, not merely a cosmetic
    mismatch.
  - **How 1380 was measured**: `ping -M do -s N` from a real workload on
    one side to the other, increasing `N` until replies stop / a
    `Frag needed ... mtu = M` ICMP appears; a `ping -s N` payload
    corresponds to an IP-layer size of `N+28` (20-byte IP + 8-byte ICMP
    header). 1380 (IP-layer) was the largest size that worked reliably,
    symmetric in both directions, for this specific tunnel (AES-GCM-256,
    ESP-in-UDP/NAT-T) over this laptop's physical path -- both the target
    number and which side can safely apply it statically are specific to
    this setup; re-measure rather than assuming they carry over to a
    different cipher suite, network path, or an architecture where the VPN
    does *not* share a netns with the VXLAN underlay.
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
