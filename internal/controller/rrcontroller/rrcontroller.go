// SPDX-License-Identifier:Apache-2.0

// Package rrcontroller implements the Route Reflector controller.
// It runs as a 2-replica Deployment on nodes where router pods run.
// Each instance configures its LOCAL node's FRR as an iBGP route reflector
// by creating a RawFRRConfig and labeling the node.
package rrcontroller

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"time"

	v1alpha1 "github.com/openperouter/openperouter/api/v1alpha1"
	"github.com/openperouter/openperouter/internal/conversion"
	"github.com/openperouter/openperouter/internal/controller/nodeindex"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
	// LabelRR is set on nodes that act as route reflectors.
	LabelRR = "openperouter.io/rr"
	// AnnotationUnderlayIP holds the node's underlay (VTEP) IP.
	AnnotationUnderlayIP = "openperouter.io/underlay-ip"

	finalizerName = "rrcontroller.openperouter.io/cleanup"
)

// RRReconciler configures the local node as a BGP route reflector.
type RRReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	MyNode    string
	Namespace string
	Logger    *slog.Logger
}

// +kubebuilder:rbac:groups=openpe.openperouter.github.io,resources=underlays,verbs=get;list;watch
// +kubebuilder:rbac:groups=openpe.openperouter.github.io,resources=rawfrrconfigs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch;update;patch

func (r *RRReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := r.Logger.With("controller", "RRController", "request", req.String())
	logger.Info("start reconcile")
	defer logger.Info("end reconcile")

	// Fetch the local node to get its index and check for deletion.
	node := &v1.Node{}
	if err := r.Get(ctx, types.NamespacedName{Name: r.MyNode}, node); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to get local node %s: %w", r.MyNode, err)
	}

	// Handle node deletion (should not normally happen, but be safe).
	if !node.DeletionTimestamp.IsZero() {
		return r.cleanup(ctx, node)
	}

	// Ensure our finalizer is present so we can clean up on pod eviction.
	if !controllerutil.ContainsFinalizer(node, finalizerName) {
		patch := client.MergeFrom(node.DeepCopy())
		controllerutil.AddFinalizer(node, finalizerName)
		if err := r.Patch(ctx, node, patch); err != nil {
			return ctrl.Result{}, fmt.Errorf("failed to add finalizer to node %s: %w", r.MyNode, err)
		}
		return ctrl.Result{Requeue: true}, nil
	}

	// Find the Underlay applicable to this node.
	underlay, err := r.findUnderlay(ctx, node)
	if err != nil {
		return ctrl.Result{}, err
	}
	if underlay == nil {
		logger.Info("no underlay found for this node, skipping")
		return ctrl.Result{}, nil
	}

	// Compute the node index.
	nodeIndex, err := r.nodeIndex(node)
	if err != nil {
		return ctrl.Result{}, err
	}

	// Compute router ID (IPv4 address from routerIDCIDR + nodeIndex).
	routerID, err := conversion.RouterIDForNode(*underlay, nodeIndex)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to compute router ID: %w", err)
	}

	// Derive peerCIDR from the underlay-ip annotation (written by the hostcontroller).
	// The annotation stores "ip/mask" (e.g. "192.168.11.3/24"); we zero the host bits
	// to get the network CIDR (e.g. "192.168.11.0/24") for bgp listen range.
	underlayAnnotation := node.Annotations[AnnotationUnderlayIP]
	if underlayAnnotation == "" {
		logger.Info("underlay-ip annotation not yet set, requeueing")
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}
	_, ipNet, err := net.ParseCIDR(underlayAnnotation)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to parse underlay-ip annotation %q: %w", underlayAnnotation, err)
	}
	peerCIDR := ipNet.String()

	// Label the node as RR (underlay-ip is written by the hostcontroller).
	if err := r.labelNode(ctx, node); err != nil {
		return ctrl.Result{}, err
	}

	// Create/update the RawFRRConfig for this node.
	if err := r.reconcileRawFRRConfig(ctx, underlay, routerID, peerCIDR); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// cleanup removes the RR label, underlay-ip annotation, RawFRRConfig, and the finalizer.
func (r *RRReconciler) cleanup(ctx context.Context, node *v1.Node) (ctrl.Result, error) {
	if err := r.deleteRawFRRConfig(ctx); err != nil {
		return ctrl.Result{}, err
	}

	patch := client.MergeFrom(node.DeepCopy())
	delete(node.Labels, LabelRR)
	controllerutil.RemoveFinalizer(node, finalizerName)
	if err := r.Patch(ctx, node, patch); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to remove finalizer from node %s: %w", r.MyNode, err)
	}
	return ctrl.Result{}, nil
}

// Shutdown removes the RR config and label for graceful pod termination.
// Call this from the controller's shutdown hook.
func (r *RRReconciler) Shutdown(ctx context.Context) {
	r.Logger.Info("RR controller shutting down, cleaning up node", "node", r.MyNode)

	if err := r.deleteRawFRRConfig(ctx); err != nil {
		r.Logger.Error("failed to delete RawFRRConfig during shutdown", "error", err)
	}

	node := &v1.Node{}
	if err := r.Get(ctx, types.NamespacedName{Name: r.MyNode}, node); err != nil {
		r.Logger.Error("failed to get node during shutdown", "error", err)
		return
	}

	patch := client.MergeFrom(node.DeepCopy())
	delete(node.Labels, LabelRR)
	controllerutil.RemoveFinalizer(node, finalizerName)
	if err := r.Patch(ctx, node, patch); err != nil {
		r.Logger.Error("failed to remove RR label/finalizer during shutdown", "error", err)
	}
}

func (r *RRReconciler) findUnderlay(ctx context.Context, node *v1.Node) (*v1alpha1.Underlay, error) {
	var underlayList v1alpha1.UnderlayList
	if err := r.List(ctx, &underlayList); err != nil {
		return nil, fmt.Errorf("failed to list underlays: %w", err)
	}
	filtered, err := filterUnderlaysForNode(node, underlayList.Items)
	if err != nil {
		return nil, fmt.Errorf("failed to filter underlays: %w", err)
	}
	if len(filtered) == 0 {
		return nil, nil
	}
	return &filtered[0], nil
}

func (r *RRReconciler) nodeIndex(node *v1.Node) (int, error) {
	if node.Annotations == nil {
		return 0, fmt.Errorf("node %s has no annotations (missing nodeindex)", r.MyNode)
	}
	idxStr, ok := node.Annotations[nodeindex.OpenpeNodeIndex]
	if !ok {
		return 0, fmt.Errorf("node %s is missing annotation %s", r.MyNode, nodeindex.OpenpeNodeIndex)
	}
	idx, err := strconv.Atoi(idxStr)
	if err != nil {
		return 0, fmt.Errorf("failed to parse node index %q: %w", idxStr, err)
	}
	return idx, nil
}

// labelNode sets the openperouter.io/rr=true label on the local node.
// The underlay-ip annotation is written by the hostcontroller, not here.
func (r *RRReconciler) labelNode(ctx context.Context, node *v1.Node) error {
	if node.Labels != nil && node.Labels[LabelRR] == "true" {
		return nil // already labeled
	}
	patch := client.MergeFrom(node.DeepCopy())
	if node.Labels == nil {
		node.Labels = make(map[string]string)
	}
	node.Labels[LabelRR] = "true"
	if err := r.Patch(ctx, node, patch); err != nil {
		return fmt.Errorf("failed to label node %s: %w", r.MyNode, err)
	}
	return nil
}

func (r *RRReconciler) reconcileRawFRRConfig(ctx context.Context, underlay *v1alpha1.Underlay, routerID, peerCIDR string) error {
	snippet := buildRRFRRSnippet(underlay.Spec.ASN, routerID, peerCIDR)
	name := rawFRRConfigName(r.MyNode)

	existing := &v1alpha1.RawFRRConfig{}
	err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: r.Namespace}, existing)
	if errors.IsNotFound(err) {
		cfg := &v1alpha1.RawFRRConfig{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: r.Namespace,
			},
			Spec: v1alpha1.RawFRRConfigSpec{
				NodeSelector: &metav1.LabelSelector{
					MatchLabels: map[string]string{
						"kubernetes.io/hostname": r.MyNode,
					},
				},
				RawConfig: snippet,
				Priority:  100,
			},
		}
		if err := r.Create(ctx, cfg); err != nil {
			return fmt.Errorf("failed to create RawFRRConfig %s: %w", name, err)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("failed to get RawFRRConfig %s: %w", name, err)
	}

	if existing.Spec.RawConfig == snippet {
		return nil // already up to date
	}

	patch := client.MergeFrom(existing.DeepCopy())
	existing.Spec.RawConfig = snippet
	if err := r.Patch(ctx, existing, patch); err != nil {
		return fmt.Errorf("failed to patch RawFRRConfig %s: %w", name, err)
	}
	return nil
}

func (r *RRReconciler) deleteRawFRRConfig(ctx context.Context) error {
	name := rawFRRConfigName(r.MyNode)
	cfg := &v1alpha1.RawFRRConfig{}
	err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: r.Namespace}, cfg)
	if errors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("failed to get RawFRRConfig %s for deletion: %w", name, err)
	}
	if err := r.Delete(ctx, cfg); err != nil && !errors.IsNotFound(err) {
		return fmt.Errorf("failed to delete RawFRRConfig %s: %w", name, err)
	}
	return nil
}

func rawFRRConfigName(nodeName string) string {
	return "rr-" + nodeName
}

// buildRRFRRSnippet generates the FRR configuration snippet for an RR node.
func buildRRFRRSnippet(asn uint32, routerID, peerCIDR string) string {
	return fmt.Sprintf(`router bgp %d
  bgp cluster-id %s
  neighbor CLIENTS peer-group
  neighbor CLIENTS remote-as %d
  bgp listen range %s peer-group CLIENTS
  address-family l2vpn evpn
    neighbor CLIENTS activate
    neighbor CLIENTS route-reflector-client
  exit-address-family
`, asn, routerID, asn, peerCIDR)
}

// filterUnderlaysForNode returns underlays that match the node's labels.
// Mirrors the logic in internal/filter but avoids an import cycle.
func filterUnderlaysForNode(node *v1.Node, underlays []v1alpha1.Underlay) ([]v1alpha1.Underlay, error) {
	var result []v1alpha1.Underlay
	for _, u := range underlays {
		if u.Spec.NodeSelector == nil {
			result = append(result, u)
			continue
		}
		sel, err := metav1.LabelSelectorAsSelector(u.Spec.NodeSelector)
		if err != nil {
			return nil, fmt.Errorf("invalid node selector for underlay %s: %w", u.Name, err)
		}
		if sel.Matches(labels.Set(node.Labels)) {
			result = append(result, u)
		}
	}
	return result, nil
}

// SetupWithManager registers the controller with the manager.
func (r *RRReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// Only reconcile when our own node changes.
	onlyLocalNode := predicate.NewPredicateFuncs(func(obj client.Object) bool {
		return obj.GetName() == r.MyNode
	})

	// When an Underlay changes, enqueue our local node so the reconcile runs.
	underlayToLocalNode := handler.EnqueueRequestsFromMapFunc(
		func(ctx context.Context, _ client.Object) []reconcile.Request {
			return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: r.MyNode}}}
		},
	)

	return ctrl.NewControllerManagedBy(mgr).
		For(&v1.Node{}, builder.WithPredicates(onlyLocalNode)).
		Watches(&v1alpha1.Underlay{}, underlayToLocalNode).
		Named("rrcontroller").
		Complete(r)
}
