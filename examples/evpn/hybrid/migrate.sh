#!/bin/bash -xe

kubectl --context gcp apply -f gcp/migrated-workload.yaml -f gcp/dst-migration.yaml  

TARGET_URL=$(kubectl --context gcp get vmim vmim-target -o jsonpath='{.status.synchronizationAddresses[0]}')

kubectl --context prem apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: vmim-source
spec:
  sendTo:
    connectURL: "${TARGET_URL}"
    migrationID: "cross-cluster-demo"
  vmiName: 192-170-1-4
EOF
