# Hybrid VNF: VLAN L2 stretch to a GCP EVPN fabric

This example stretches a Layer 2 VLAN from an on-premises **VNF** (a single
OpenPERouter instance running as a systemd/Podman service, **no Kubernetes**)
to a GCP OpenShift cluster running OpenPERouter, over an IPsec Cloud VPN, using
EVPN/VXLAN.

It is the cloud-VPN, single-VNF variant of [`../hybrid`](../hybrid): the
on-prem side is not a Kubernetes cluster but one container-based router that
also terminates the VPN, so you can exercise the cloud-VPN overhead and the
VLAN attachment without a second cluster.

```
        ON-PREM (laptop)                              GCP OpenShift (ellorent-vlan-evpn)
  ┌───────────────────────────┐                ┌──────────────────────────────────────────┐
  │ OpenPERouter VNF (systemd) │                │ worker-a  worker-b  worker-c              │
  │  FRR + reloader + strongSwan│               │  (RR)     (client)  (client)              │
  │  netns "perouter"          │  IPsec Cloud   │  ipvlan-l3 VTEP on br-ex                  │
  │  VTEP 100.65.0.0/24 on eth1 │◄────VPN───────►│  VTEP 10.0.200.x (alias IP)              │
  │  L2VNI 110  ── br-vlan ──┐  │                │  L2VNI 110 ── br-hs-110 ── pod           │
  └──────────────────────────┼──┘               └──────────────────────────────────────────┘
                             │
                     workload VLAN (eth2.100)
```

- On-prem VNF ASN `64514`, VTEP pool `100.65.0.0/24` (index 0 -> `100.65.0.0`).
- GCP workers share ASN `65001`; the first worker is a **BGP route reflector**,
  the others are clients. The VNF peers the RR's VTEP `10.0.200.1` with an
  **eBGP-multihop** session over the VPN, so one session exchanges every VTEP
  and all the EVPN type-2/type-3 routes.
- One **disconnected L2VNI** (`vni 110`) is stretched between the sides: on GCP
  a pod on `br-hs-110`, on-prem a workload VLAN bridged into `br-vlan`. Pure
  east-west L2, no gateway.

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
  env.sh                 discovers infra ID / worker nodes / subnet
  openshift/install.sh   Helm-install OpenPERouter + SCCs
  underlay.sh            route reflector + clients Underlays (ipvlan L3 CNIDevice)
  alias-ip.sh            register each worker VTEP as an instance alias IP
  setup-cloudvpn.sh      Classic Cloud VPN to the laptop + route + firewall
  l2vni.yaml             stretched L2VNI + NAD + workload pod
kubeconfig.sh            pull the cluster kubeconfig from the Jenkins artifact
```

## Prerequisites

- **On-prem (laptop):** Podman + systemd, root, a **spare NIC** for the underlay
  (moved into the router netns, unusable by the host afterwards) and a NIC for
  the workload VLAN. A public IP reachable by GCP for the VPN.
- **GCP:** an OpenShift cluster (this PoC targets `ellorent-vlan-evpn`, CNV
  4.22, 3 workers), `oc` with its kubeconfig, and `gcloud` authenticated to the
  project (`gcloud auth login`). The project is shared, so every script is
  scoped to the cluster infra ID.
- No persistent storage / VMs are required — the workload is a plain pod.

## Run

Fill in the VPN parameters in `gcp/network.env` (`SHARED_SECRET`, and after the
VPN is created, `GCP_VPN_IP`), and set the underlay/VLAN NIC names.

### 1. GCP side

```bash
export KUBECONFIG=$(find $PWD/../../../cluster-dirs -path '*/auth/kubeconfig')   # or ./kubeconfig.sh <jenkins-build-url>
cd gcp
source network.env                 # SHARED_SECRET, ONPREM_PUBLIC_IP (or autodetected)
./openshift/install.sh             # OpenPERouter on the cluster
./underlay.sh                      # route reflector + clients
./alias-ip.sh                      # VTEP alias IPs on the worker instances
./setup-cloudvpn.sh                # Cloud VPN to the laptop -> prints GCP_VPN_IP
oc apply -f l2vni.yaml             # stretched L2VNI + NAD + workload pod
```

Put the printed `GCP_VPN_IP` into `network.env`.

### 2. On-prem VNF (laptop, as root)

Edit `vnf/config/configs/openpe_config.yaml` and set the underlay
`interfaceName` to your spare NIC. Then:

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

## Teardown

```bash
# on-prem
sudo ./vnf/undeploy.sh
# GCP (delete the infra-ID-scoped VPN/route/firewall, alias IPs, and CRs)
oc delete -f gcp/l2vni.yaml
oc delete underlay -n openperouter-system route-reflector route-reflector-clients
# remove the Cloud VPN resources created by setup-cloudvpn.sh with gcloud if desired
```

## Notes

- **Static / cluster-less:** the VNF controller runs in `--mode host` and reads
  only `node-config.yaml` + `configs/openpe_*.yaml`. With no Kubernetes API it
  logs *"continue with static config only"* and keeps the datapath reconciled —
  this is expected, not an error.
- **strongSwan sidecar:** the VPN runs in the router pod's `perouter` netns
  (`Pod=routerpod.pod`) so the tunnel, the VTEP and BGP share one routing
  table. The upstream `openperouter/router` image is untouched.
- **Deterministic VTEPs:** GCP VTEPs are derived from `GCP_VTEP_CIDR` and the
  node index (`openpe.io/nodeindex`), so `alias-ip.sh` can assign them without
  discovering a dynamic lease. `vtep.sh` reproduces the calculation.
- **Shared project:** every `gcloud` call is scoped to the cluster infra ID; do
  not loosen the filters — other clusters share `ocpstrat-1278`.
