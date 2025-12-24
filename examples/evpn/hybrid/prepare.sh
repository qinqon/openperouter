#!/bin/bash
set -euo pipefail
set -x
CURRENT_PATH=$(dirname "$0")

source "${CURRENT_PATH}/../../common.sh"

install_whereabouts() {
    echo "Installing Whereabouts CNI plugin"

    kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/refs/heads/master/doc/crds/daemonset-install.yaml
    kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/refs/heads/master/doc/crds/whereabouts.cni.cncf.io_ippools.yaml
    kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/refs/heads/master/doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml

    kubectl rollout status daemonset/whereabouts -n kube-system --timeout=5m

    echo "Whereabouts CNI plugin installed successfully"
}

install_kubevirt() {
    kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.6.2/kubevirt-operator.yaml
    kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.6.2/kubevirt-cr.yaml

    # Patch KubeVirt with:
    # - allow scheduling on control-planes
    # - enable decentralized live migration feature gate
    # - configure migration network
    kubectl patch -n kubevirt kubevirt kubevirt --type merge --patch '{
        "spec": {
            "workloads": {
                "nodePlacement": {
                    "tolerations": [
                        {
                            "key": "node-role.kubernetes.io/control-plane",
                            "operator": "Exists",
                            "effect": "NoSchedule"
                        }
                    ]
                }
            },
            "configuration": {
                "developerConfiguration": {
                    "featureGates": ["DecentralizedLiveMigration"]
                },
                "migrations": {
                    "network": "migration-evpn"
                }
            }
        }
    }'

    kubectl wait --for=condition=Available kubevirt/kubevirt -n kubevirt --timeout=10m
}

exchange_kubevirt_certificates() {
    echo "Exchanging KubeVirt certificates between clusters"

    local ca_bundle_prem=$(kubectl --context prem get configmap kubevirt-ca -n kubevirt -o jsonpath='{.data.ca-bundle}' 2>/dev/null || echo "")
    if [[ -z "$ca_bundle_prem" ]]; then
        echo "Warning: Could not read kubevirt-ca configmap from prem cluster, skipping certificate exchange"
        return 1
    fi

    local ca_bundle_gcp=$(kubectl --context gcp get configmap kubevirt-ca -n openshift-cnv -o jsonpath='{.data.ca-bundle}' 2>/dev/null || echo "")
    if [[ -z "$ca_bundle_gcp" ]]; then
        echo "Warning: Could not read kubevirt-ca configmap from gcp cluster, skipping certificate exchange"
        return 1
    fi

    echo "Setting gcp cluster CA certificate in prem cluster kubevirt-external-ca configmap"
    kubectl --context prem create configmap kubevirt-external-ca -n kubevirt --from-literal=ca-bundle="$ca_bundle_gcp" --dry-run=client -o yaml | \
        kubectl --context prem apply -f -

    echo "Setting prem cluster CA certificate in gcp cluster kubevirt-external-ca configmap"
    kubectl --context prem create configmap kubevirt-external-ca -n openshift-cnv --from-literal=ca-bundle="$ca_bundle_prem" --dry-run=client -o yaml | \
        kubectl --context gcp apply -f -

    echo "KubeVirt certificate exchange completed successfully"
}

# KUBECONFIG should point to the GCP cluster the context name should be "admin"
# Provision dedicated migration network before KubeVirt CCLM activation
setup_gcp() {
   ./gcp/openshift/install.sh
   kubectl apply -f gcp/migration-l2vni.yaml -f gcp/migration-nad.yaml
   ./gcp/openshift/prepare.sh
   ./gcp/setup.sh
}

setup_prem() {
   source /tmp/gcp-vpn-config.env
   make -C ${CURRENT_PATH}/../../../ docker-build undeploy-hybrid deploy-hybrid
}

flatten_kubeconfig() {
	# Now we flatten both kubeconfig files into one
	KUBECONFIG=$KUBECONFIG:../../../bin/kubeconfig \
		kubectl config view --flatten > kubeconfig

	export KUBECONFIG=${CURRENT_PATH}/kubeconfig

	# Rename context so it's clearer
	# admin -> gcp
	# kind-pe-kind -> prem
	if kubectl config get-contexts admin > /dev/null 2>&1; then
		kubectl config rename-context admin gcp
	fi

	if kubectl config get-contexts kind-pe-kind > /dev/null 2>&1; then
		kubectl config rename-context kind-pe-kind prem
	fi
}

apply_demo_manifests() {
	# Apply demo manifests
	kubectl config use-context gcp
	./gcp/underlay.sh
	kubectl apply -f gcp/vni.yaml
	# Wait for the br-hs-110 bridge to be detected by the bridge-marker
	echo "Waiting for bridge br-hs-110 annotation on worker nodes..."
	timeout 2m bash -c '
		until kubectl get nodes -o jsonpath="{.items[*].status.capacity}" | grep -q "bridge\.network\.kubevirt\.io/br-hs-110"; do
			sleep 2
		done
	'
	echo "Bridge br-hs-110 is ready"
	kubectl apply -f gcp/workload.yaml

	kubectl config use-context prem
	kubectl apply -f prem/underlay.yaml -f prem/vni.yaml -f prem/workload.yaml
}

main() {
	setup_gcp
	setup_prem

	flatten_kubeconfig

	kubectl config use-context prem

	# Install Whereabouts CNI plugin before KubeVirt since we want the
	# KubeVirt installation to know which migration network to use.
	# KubeVirt's dedicated migration network requires whereabouts IPAM.
	install_whereabouts

	# Provision dedicated migration network before KubeVirt installation
	kubectl apply -f prem/migration-l2vni.yaml -f prem/migration-nad.yaml

	install_kubevirt
	
	apply_demo_manifests
	
	exchange_kubevirt_certificates gcp prem
}

if [[ "$@" == "" ]]; then
	main
else
	$@
fi
