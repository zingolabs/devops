#!/usr/bin/env bash
# Extract a kubeconfig for a ServiceAccount created by cluster-access chart.
#
# Usage:  ./scripts/extract-kubeconfig.sh <username>
# Output: ./<username>-kubeconfig.yaml
#
# Prereqs: the cluster-access chart must already be synced (SA + token exist).
# The recipient also needs Tailscale access to reach the API server.

set -euo pipefail

USERNAME="${1:?Usage: $0 <username>}"
SA_NS="default"
OUT="${USERNAME}-kubeconfig.yaml"

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

TOKEN=$(kubectl get secret "${USERNAME}-token" -n "${SA_NS}" \
  -o jsonpath='{.data.token}' | base64 -d)

if [ -z "${TOKEN}" ]; then
  echo "ERROR: token not found — is the cluster-access chart synced?" >&2
  exit 1
fi

cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
contexts:
- name: ${USERNAME}@${CLUSTER}
  context:
    cluster: ${CLUSTER}
    user: ${USERNAME}
current-context: ${USERNAME}@${CLUSTER}
users:
- name: ${USERNAME}
  user:
    token: ${TOKEN}
EOF

chmod 600 "${OUT}"
echo "Written: ${OUT}"
echo ""
echo "Give to the user (securely). They run:"
echo "  export KUBECONFIG=\$(pwd)/${OUT}"
echo "  k9s"
