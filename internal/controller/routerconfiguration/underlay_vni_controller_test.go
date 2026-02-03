// SPDX-License-Identifier:Apache-2.0

package routerconfiguration

import (
	"context"
	"testing"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/openperouter/openperouter/api/v1alpha1"
)

func TestGetRouteReflectorIPs(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = v1.AddToScheme(scheme)
	_ = v1alpha1.AddToScheme(scheme)

	tests := []struct {
		name        string
		namespace   string
		pods        []v1.Pod
		expectedIPs []string
	}{
		{
			name:      "No RR pods",
			namespace: "openperouter-system",
			pods:      []v1.Pod{},
			expectedIPs: nil,
		},
		{
			name:      "RR pods with correct labels and ready",
			namespace: "openperouter-system",
			pods: []v1.Pod{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-1",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.10",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionTrue},
							{Type: v1.ContainersReady, Status: v1.ConditionTrue},
						},
					},
				},
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-2",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.11",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionTrue},
							{Type: v1.ContainersReady, Status: v1.ConditionTrue},
						},
					},
				},
			},
			expectedIPs: []string{"10.244.1.10", "10.244.1.11"},
		},
		{
			name:      "RR pods not ready",
			namespace: "openperouter-system",
			pods: []v1.Pod{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-1",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.10",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionFalse},
							{Type: v1.ContainersReady, Status: v1.ConditionFalse},
						},
					},
				},
			},
			expectedIPs: nil,
		},
		{
			name:      "RR pods without IP",
			namespace: "openperouter-system",
			pods: []v1.Pod{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-1",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionTrue},
							{Type: v1.ContainersReady, Status: v1.ConditionTrue},
						},
					},
				},
			},
			expectedIPs: nil,
		},
		{
			name:      "RR pods in different namespace",
			namespace: "openperouter-system",
			pods: []v1.Pod{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-1",
						Namespace: "other-namespace",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.10",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionTrue},
							{Type: v1.ContainersReady, Status: v1.ConditionTrue},
						},
					},
				},
			},
			expectedIPs: nil,
		},
		{
			name:      "Pods without RR label",
			namespace: "openperouter-system",
			pods: []v1.Pod{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "other-pod",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app": "router",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.10",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionTrue},
							{Type: v1.ContainersReady, Status: v1.ConditionTrue},
						},
					},
				},
			},
			expectedIPs: nil,
		},
		{
			name:      "Mix of ready and not ready RR pods",
			namespace: "openperouter-system",
			pods: []v1.Pod{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-1",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.10",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionTrue},
							{Type: v1.ContainersReady, Status: v1.ConditionTrue},
						},
					},
				},
				{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "rr-2",
						Namespace: "openperouter-system",
						Labels: map[string]string{
							"app.kubernetes.io/component": "route-reflector",
						},
					},
					Status: v1.PodStatus{
						PodIP: "10.244.1.11",
						Conditions: []v1.PodCondition{
							{Type: v1.PodReady, Status: v1.ConditionFalse},
							{Type: v1.ContainersReady, Status: v1.ConditionFalse},
						},
					},
				},
			},
			expectedIPs: []string{"10.244.1.10"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create fake client with pods
			objs := make([]runtime.Object, len(tt.pods))
			for i := range tt.pods {
				objs[i] = &tt.pods[i]
			}
			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithRuntimeObjects(objs...).Build()

			reconciler := &PERouterReconciler{
				Client:      fakeClient,
				MyNamespace: tt.namespace,
			}

			ips, err := reconciler.getRouteReflectorIPs(context.Background())
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if len(ips) != len(tt.expectedIPs) {
				t.Errorf("expected %d IPs, got %d: %v", len(tt.expectedIPs), len(ips), ips)
				return
			}

			for i, expectedIP := range tt.expectedIPs {
				if ips[i] != expectedIP {
					t.Errorf("expected IP[%d] = %s, got %s", i, expectedIP, ips[i])
				}
			}
		})
	}
}
