#!/bin/bash
set -euo pipefail

# Install k3s on production server (tekau)
# Run this once on the target machine

DATA_DIR="${DATA_DIR:-/data/k3s}"

echo "Installing k3s with data directory: $DATA_DIR"

curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --data-dir "$DATA_DIR" \
  --write-kubeconfig-mode 644

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo ""
echo "Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.3/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo ""
echo "Applying root application..."
kubectl apply -f bootstrap/argocd-bootstrap.yaml

echo ""
echo "Access ArgoCD:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Username: admin"
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo "  Password: $PASS"
echo ""
echo "Add to your shell:"
echo "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
