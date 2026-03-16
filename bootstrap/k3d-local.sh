#!/bin/bash
set -euo pipefail

# Create k3d cluster for local development
# Mirrors production setup but with smaller resources

CLUSTER_NAME="${CLUSTER_NAME:-zingolabs-dev}"

echo "Creating k3d cluster: $CLUSTER_NAME"

k3d cluster create "$CLUSTER_NAME" \
  --servers 1 \
  --agents 1 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --port "9067:9067@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

echo "Cluster created."
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
