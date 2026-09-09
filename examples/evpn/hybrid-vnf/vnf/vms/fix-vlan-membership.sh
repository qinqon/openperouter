#!/bin/bash
#
# Run this locally on the hypervisor once vm-router and vm-workload exist
# (right after `kcli create plan -f kcli-plan.yml ...` -- see that file's
# own header comment for why this is a separate, explicit step rather than
# a kcli "workflow" plan entry run automatically as part of the same
# invocation).
#
# kcli/libvirt's plain "bridge" NIC attachment (used for both VMs'
# sim-switch-attached NIC) has no concept of the VLAN-aware bridge's own
# VLAN filtering: a freshly-attached tap defaults to PVID 1, untagged --
# which does NOT match sim-switch's trunk/access ports (VLAN 100, see
# ../sim-switch-setup.sh), leaving the VM completely isolated from the
# stretched L2 segment ("Destination Host Unreachable", not just packet
# loss, since there's no L2 path at all). Fix the two ports' VLAN
# membership directly, mirroring what a real switch port's config would be:
#   - vm-router's trunk NIC: tagged member of VLAN 100 (like a switch
#     uplink to a router).
#   - vm-workload's access NIC: untagged/PVID member of VLAN 100 (like an
#     end host plugged into an access port).
#
# Usage:
#   ./fix-vlan-membership.sh
#   VLAN_ID=200 ./fix-vlan-membership.sh
set -uo pipefail

VLAN_ID="${VLAN_ID:-100}"
TIMEOUT="${TIMEOUT:-60}"

tap_for() {
    # vm name -> the tap device on the "sim-switch" bridge (second/last nic
    # depending on the vm -- vm-router has 3 nics, vm-workload has 2, but
    # sim-switch is always the last one for both, see kcli-plan.yml's nets:
    # order). sudo even for this read-only query: plain `virsh` (unlike
    # `kcli` itself, which manages the same libvirt connection fine as an
    # unprivileged user in the "libvirt"/"qemu" groups, presumably via a
    # different access path) failed outright ("failed to get domain") for
    # these kcli-created domains without it.
    sudo virsh domiflist "$1" 2>/dev/null | awk '$3 == "sim-switch" {print $1}'
}

for vm in vm-router vm-workload; do
    # Poll rather than assume the domain (and its nic) already exists: if
    # this runs immediately after `kcli create plan` returns, the domain
    # is normally already fully defined by then, but the extra robustness
    # is cheap and matches add-underlay-route.sh's same wait-for-it
    # philosophy for another async dependency in this same workflow.
    tap=""
    for ((i = 0; i < TIMEOUT; i++)); do
        tap="$(tap_for "${vm}")"
        [[ -n "${tap}" ]] && break
        sleep 1
    done
    if [[ -z "${tap}" ]]; then
        echo "[fix-vlan-membership] no sim-switch tap found for ${vm} after ${TIMEOUT}s, skipping" >&2
        continue
    fi
    sudo bridge vlan del dev "${tap}" vid 1 2>/dev/null || true
    if [[ "${vm}" == "vm-workload" ]]; then
        sudo bridge vlan add dev "${tap}" vid "${VLAN_ID}" pvid untagged
    else
        sudo bridge vlan add dev "${tap}" vid "${VLAN_ID}"
    fi
    echo "[fix-vlan-membership] ${vm}: ${tap} -> vlan ${VLAN_ID}"
    sudo bridge vlan show dev "${tap}"
done
