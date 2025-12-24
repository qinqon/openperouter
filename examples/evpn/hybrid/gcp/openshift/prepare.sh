#!/bin/bash -xe

CURRENT_PATH=$(dirname "$0")

# Patch HCO with:
# - enable decentralized live migration feature gate
# - move virt-synchronization-controller to worker nodes
# - configure migration network
kubectl annotate --overwrite -n openshift-cnv hyperconverged kubevirt-hyperconverged \
  'kubevirt.kubevirt.io/jsonpatch=[
    {"op": "add", "path": "/spec/configuration/developerConfiguration/featureGates/-", "value": "DecentralizedLiveMigration"},
    {"op": "add", "path": "/spec/customizeComponents", "value": {"patches": [{"resourceName": "virt-synchronization-controller", "resourceType": "Deployment", "type": "strategic", "patch": "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"node-role.kubernetes.io/worker\",\"operator\":\"Exists\"}]}]}}},\"nodeSelector\":{\"node-role.kubernetes.io/worker\":\"\"}}}}}"}]}}
  ]'

kubectl patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=merge --patch '{
    "spec": {
      "liveMigrationConfig": {
        "network": "migration-evpn"
      }
    }
}'

kubectl wait --for=condition=Available kubevirt/kubevirt-kubevirt-hyperconverged -n openshift-cnv --timeout=10m

