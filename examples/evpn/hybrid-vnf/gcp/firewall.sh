#!/bin/bash
#
# Opens the GCP firewall for intra-cluster EVPN underlay traffic (BGP and
# VXLAN) between the worker VTEPs and the control-plane route reflectors.
#
# The OpenShift installer's own rules do not reliably cover this. The
# internal-cluster rule looks like it should: it matches by source/target
# TAGS (worker, control-plane) and already allows udp:4789. In practice it
# does not reliably pass VXLAN traffic sourced from a GCP alias IP (the VTEP
# addresses are alias IPs, not the instance's primary IP) -- GCP's tag-based
# source matching does not consistently attribute alias-IP-sourced packets to
# the owning instance's tags the way it does for the primary IP. The
# internal-network rule (source 10.0.0.0/16) only allows tcp:22 and icmp, so
# it masks the problem for ICMP (ping between VTEPs looks fine) while BGP
# (tcp:179) and VXLAN (udp:4789) both silently fail. A plain CIDR-based
# source-ranges rule -- matching by IP instead of instance tag -- reliably
# passes alias-IP-sourced traffic; the original GCP PoC hit and worked around
# the same issue (see examples/evpn/hybrid/gcp/setup.sh's own
# "*-openperouter-network" rule upstream).
#
# Scoped strictly to the cluster infra ID because the project is shared.
#
# Requires: env.sh sourced (gcloud authenticated to the project).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"

RULE="${CLUSTER_INFRA_ID}-vtep-underlay"
RULES="tcp:179,udp:4789,icmp"
SOURCE_RANGES="${GCP_VTEP_CIDR},${GCP_RR_CIDR}"

if gcloud compute firewall-rules describe "$RULE" --project="$GCP_PROJECT_ID" &>/dev/null; then
    echo "updating existing firewall rule ${RULE}"
    gcloud compute firewall-rules update "$RULE" \
        --project="$GCP_PROJECT_ID" \
        --rules="$RULES" \
        --source-ranges="$SOURCE_RANGES"
    exit 0
fi

gcloud compute firewall-rules create "$RULE" \
    --project="$GCP_PROJECT_ID" \
    --network="$GCP_NETWORK" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="$RULES" \
    --source-ranges="$SOURCE_RANGES" \
    --description="OpenPERouter EVPN underlay BGP+VXLAN between GCP VTEPs and route reflectors (hybrid-vnf PoC). CIDR-based, not tag-based: GCP does not reliably match alias-IP-sourced traffic by instance tag."
