#!/bin/bash
#
# Downloads the OpenShift cluster kubeconfig (and metadata) from the CNV GCP-IPI
# Jenkins deploy job artifact and extracts it locally, mirroring the PoC helper.
#
# Usage:
#   ./kubeconfig.sh <jenkins-build-url>
# e.g.
#   ./kubeconfig.sh https://jenkins-csb-cnvqe-main.dno.corp.redhat.com/job/deploy-cnv-4.22-on-gcp-ipi/81
#
# Afterwards:
#   export KUBECONFIG=$(find cluster-dirs -path '*ellorent-vlan-evpn*/auth/kubeconfig')
set -euo pipefail

JENKINS_URL="${1:?usage: $0 <jenkins-build-url>}"
JENKINS_URL="${JENKINS_URL%/}"

ZIP_PATH=$(curl -s "${JENKINS_URL}/api/json" \
    | jq -r '.artifacts[] | select(.fileName | endswith("-data.zip")) | .relativePath' | head -1)
if [[ -z "${ZIP_PATH}" ]]; then
    echo "no *-data.zip artifact found on ${JENKINS_URL}" >&2
    exit 1
fi

echo "downloading ${JENKINS_URL}/artifact/${ZIP_PATH}"
curl -s "${JENKINS_URL}/artifact/${ZIP_PATH}" | bsdtar -xf -
echo "extracted. kubeconfig:"
find cluster-dirs -path '*/auth/kubeconfig' 2>/dev/null || true
