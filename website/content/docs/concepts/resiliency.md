---
weight: 30
title: "Router Resiliency"
description: "How OpenPERouter survives router pod restarts without data plane disruption"
icon: "article"
date: "2025-06-15T15:03:22+02:00"
lastmod: "2025-06-15T15:03:22+02:00"
toc: true
---

OpenPERouter provides data plane resiliency by decoupling the network namespace
lifecycle from the router pod lifecycle. When the router pod crashes or
restarts, traffic continues flowing through the existing kernel forwarding
state while the control plane recovers via BGP Graceful Restart.

## Named Network Namespace

By default, Kubernetes destroys a pod's network namespace when the pod
terminates. This tears down all interfaces, routes, and forwarding state,
causing a full data plane outage until the replacement pod rebuilds everything.

OpenPERouter avoids this by running the router inside a **persistent named
network namespace** (`/var/run/netns/perouter`). The namespace is created by
the controller and held open by a bind mount, independent of any container
lifecycle. The router pod joins this pre-existing namespace instead of using
its own.

When the router pod dies:

1. The named namespace persists because it is held by a bind mount, not by the
   pod process.
2. All kernel networking state survives: VRFs, bridges, VXLAN interfaces,
   routes, FDB entries, and the underlay NIC remain intact.
3. The kernel continues forwarding packets using its existing routing and
   bridging tables.
4. When the replacement pod starts, it enters the same named namespace and
   finds all interfaces already configured.

## BGP Graceful Restart

While the data plane continues forwarding during a router restart, BGP sessions
with the fabric and host peers will drop. Without Graceful Restart, peers would
immediately withdraw all routes learned from the restarting router, causing
traffic blackholes even though the data plane is still functional.

BGP Graceful Restart solves this by having peers preserve stale routes for a
configurable period while the restarting router recovers. The restarting router
re-establishes its BGP sessions and refreshes its routes before the stale timer
expires, resulting in no route withdrawal and no traffic disruption.

OpenPERouter supports BGP Graceful Restart through the `gracefulRestart` field
on the Underlay resource. See the
[EVPN configuration]({{< ref "/docs/configuration/evpn#bgp-graceful-restart" >}})
page for details on how to enable and configure it.

## Recovery Timeline

A typical recovery sequence after a router pod crash:

1. **0s**: Router pod crashes. The named netns and all interfaces persist.
   Kernel continues forwarding with existing state.
2. **~5-10s**: Kubernetes detects the pod failure and schedules a replacement.
3. **~10-15s**: The new router pod starts and FRR enters the existing named
   namespace.
4. **~15-25s**: FRR re-establishes BGP sessions using Graceful Restart. Peers
   refresh their routes.
5. **Ongoing**: Normal operation resumes with no data plane interruption.

During steps 1-4, the data plane remains operational. Traffic that relies on
already-learned routes and FDB entries continues to flow without interruption.

## Automatic Netns Recovery

If the named network namespace is destroyed (for example, by an administrator
running `ip netns delete perouter`), the controller detects the loss and
automatically recreates it. The controller then re-provisions all network
interfaces and the router pod is restarted to rejoin the new namespace. This
provides an additional layer of robustness, although a full data plane rebuild
is required in this case.
