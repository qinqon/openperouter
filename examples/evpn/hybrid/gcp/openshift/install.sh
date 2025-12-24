#!/bin/bash -xe

CURRENT_PATH=$(dirname "$0")

#helm repo add openperouter https://openperouter.github.io/openperouter

#helm repo update
#helm install openperouter openperouter/openperouter -f values.yaml -n openperouter-system --create-namespace

helm uninstall --ignore-not-found openperouter -n openperouter-system
helm install openperouter ${CURRENT_PATH}/../../../../../charts/openperouter/ --namespace openperouter-system -f ${CURRENT_PATH}/values.yaml --create-namespace
kubectl apply -f ${CURRENT_PATH}/ipvlan.yaml
	
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-controller
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-perouter

kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/l2vnis.openpe.openperouter.github.io
kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/l3vnis.openpe.openperouter.github.io
kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/underlays.openpe.openperouter.github.io

kubectl -n openperouter-system wait --for=condition=Ready --all pods --timeout=5m
