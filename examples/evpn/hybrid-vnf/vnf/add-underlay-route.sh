#!/bin/bash
#
# Adds perouter's default route once the underlay NetworkDevice interface has
# been moved in by the controller (it preserves addresses but not routes --
# see config/configs/openpe_config.yaml). Waits for the interface first: the
# move happens asynchronously inside the controller container's own
# reconciliation loop (a separate pod/service from routerpod, which only
# creates the empty netns + loopback in its own ExecStartPre) -- on a
# from-scratch deploy this can take longer than deploy.sh itself runs for,
# so calling this immediately after deploy.sh without waiting reliably fails
# with "Cannot find device" (a plain, non-waiting version of this was
# originally tried directly in the routerpod quadlet's ExecStartPost, which
# has the same problem but *also* blocks that unit's own "active" status for
# however long the wait takes -- moved here instead, where waiting longer
# costs nothing).
#
# Reads UNDERLAY_IFACE/UNDERLAY_GW from the environment if set (e.g. called
# right after deploy.sh, which already has them), otherwise from
# /etc/openpe-vnf/underlay.env (written by deploy.sh -- see network.env).
# No-ops cleanly if neither source has them, in which case add the route by
# hand as documented in config/configs/openpe_config.yaml.
#
# Usage:
#   ./add-underlay-route.sh                       # reads underlay.env
#   UNDERLAY_IFACE=enp2s0 UNDERLAY_GW=192.168.1.1 ./add-underlay-route.sh
set -uo pipefail

ENV_FILE="/etc/openpe-vnf/underlay.env"
if [[ -z "${UNDERLAY_IFACE:-}" || -z "${UNDERLAY_GW:-}" ]] && [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

if [[ -z "${UNDERLAY_IFACE:-}" || -z "${UNDERLAY_GW:-}" ]]; then
    echo "[add-underlay-route] UNDERLAY_IFACE/UNDERLAY_GW not set (env or ${ENV_FILE}); skipping." >&2
    exit 0
fi

TIMEOUT="${TIMEOUT:-120}"
echo "[add-underlay-route] waiting up to ${TIMEOUT}s for ${UNDERLAY_IFACE} inside perouter..."
for ((i = 0; i < TIMEOUT; i++)); do
    if ip netns exec perouter ip link show "${UNDERLAY_IFACE}" &>/dev/null; then
        ip netns exec perouter ip route replace default via "${UNDERLAY_GW}" dev "${UNDERLAY_IFACE}"
        echo "[add-underlay-route] done after ${i}s: default via ${UNDERLAY_GW} dev ${UNDERLAY_IFACE}"
        exit 0
    fi
    sleep 1
done

echo "[add-underlay-route] ${UNDERLAY_IFACE} never appeared inside perouter after ${TIMEOUT}s; add the route by hand (see config/configs/openpe_config.yaml)." >&2
exit 1
