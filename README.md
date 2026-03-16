# ZingoLabs DevOps

GitOps repository for ZingoLabs infrastructure.

## Structure

```
devops/
├── bootstrap/          # One-time cluster setup scripts
├── platform/           # Cluster infrastructure (ArgoCD, monitoring)
├── apps/               # Application deployments
│   ├── zebra/          # Zebra validator nodes
│   └── zaino/          # Zaino indexer deployments
└── clusters/           # Environment-specific overlays
    ├── local/          # k3d local development
    └── production/     # Beefy machine (tekau)
```

## Quick Start

### Local Development (k3d)

```bash
./bootstrap/k3d-local.sh
kubectl apply -f bootstrap/argocd-bootstrap.yaml
```

### Production (tekau)

```bash
./bootstrap/k3s-production.sh
kubectl apply -f bootstrap/argocd-bootstrap.yaml
```

## Components

### Persistent (always running)
- Zebra Mainnet - synced validator
- Zebra Testnet - synced validator
- Zaino Stable Mainnet - baseline indexer
- Zaino Stable Testnet - baseline indexer

### Ephemeral (RC testing)
- Zaino RC slots - spun up for release candidate validation
