#!/bin/bash
#
# Cloud-init first-boot automation for vm-router: deploys the on-prem
# OpenPERouter VNF quadlet stack (see ../deploy.sh) with no manual SSH steps
# after `kcli create plan`. Runs once, as root, via cloud-init's runcmd stage
# (kcli injects it as a "scripts" entry -- see kcli-plan.yml).
#
# This file is rendered through Jinja by kcli at `kcli create plan` time:
# {{ SHARED_SECRET }}, {{ GCP_VPN_IP }} and {{ uplink_gw }} come from plan
# parameters (see kcli-plan.yml's "parameters" section and secrets.yml.sample)
# and are substituted here before the file ever reaches the VM. Only the
# *rendered* result briefly exists on this VM's own disk -- same exposure as
# placing them there by hand, and never committed to git.
set -euo pipefail
exec > /var/log/vm-router-init.log 2>&1
echo "=== vm-router-init: $(date) ==="

echo "--- installing packages ---"
dnf install -y git podman systemd-container

echo "--- cloning the example repo (HTTPS: no key material needed in-guest) ---"
REPO=/root/openperouter
rm -rf "${REPO}"
git clone --branch '{{ vnf_branch }}' --depth 1 '{{ vnf_repo_url }}' "${REPO}"
VNF_DIR="${REPO}/examples/evpn/hybrid-vnf/vnf"

# Some Fedora Cloud image builds leave the /sys mountpoint directory
# mislabeled (mock_var_lib_t instead of sysfs_t -- apparently inherited from
# however the image itself was built). This blocks "ip netns exec" when
# launched by systemd specifically (though not interactively), which the
# routerpod quadlet needs for its ExecStartPre. `touch /.autorelabel;
# reboot` does not fix it: the mislabel is on the mountpoint directory
# itself, permanently hidden under the live sysfs mount, so a normal
# relabel pass never reaches it. Permissive is the pragmatic fix for this
# disposable VM; see the README's SELinux gotcha for the full root-cause
# writeup and the (riskier) alternative of unmounting /sys in an isolated
# mount namespace to relabel it directly.
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0

echo "--- writing secrets (rendered here, never committed to git) ---"
cat > /root/network.env.local <<SECRETS
export SHARED_SECRET='{{ SHARED_SECRET }}'
export GCP_VPN_IP='{{ GCP_VPN_IP }}'
SECRETS
chmod 600 /root/network.env.local

echo "--- workload VLAN bridge (br-vlan), trunk on enp3s0 ---"
VLAN_NIC=enp3s0 VLAN_ID=100 "${VNF_DIR}/vlan-setup.sh"

echo "--- deploying the VNF quadlet stack ---"
set -a
# shellcheck disable=SC1091
source /root/network.env.local
set +a
UNDERLAY_IFACE=enp2s0 UNDERLAY_GW='{{ uplink_gw }}' "${VNF_DIR}/deploy.sh"

echo "--- adding perouter's default route (waits for the controller's async interface move) ---"
UNDERLAY_IFACE=enp2s0 UNDERLAY_GW='{{ uplink_gw }}' "${VNF_DIR}/add-underlay-route.sh" || true

echo "=== vm-router-init: done $(date) ==="
touch /root/vm-router-init.done
