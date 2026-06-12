# 2026-06-09 — Cluster audit, cleanup, and deployment taxonomy

## Cluster audit

Full audit of the cluster state. Found 8 stale ephemeral namespaces consuming ~1.9 TiB:
- tryout-1/2/3 (49d old, 500Gi each — from early RC testing, never cleaned up)
- serve-dev, serve-dev-fresh (42d, stale dev images)
- serve-structured-tracing, serve-tracing-cached (42d, 0/1 dead pods)
- logging-test (48d, dead)

All deleted. The tryout namespaces alone were 1.5 TiB of orphaned storage.

## Crashloop investigation

Every zaino pod across all namespaces was restarting ~30 times/day. Root cause: zaino hard-exits (exit code 1) when zebra becomes transiently unreachable. The init-rpc containers are innocent — they only run once at pod startup. The main zaino process calls `unwrap()` on the validator connection and panics. Tracked in zaino#982.

## Deployment taxonomy

Identified four deployment categories:
- **Golden** (ever-running, ArgoCD-managed): golden-mainnet, golden-testnet
- **Branch-tracking** (ever-running, auto-advancing): dev tracking
- **RC validation** (ephemeral, Argo Workflows): long-sync + pre-cached-at-tip
- **Feature test** (ephemeral, PR-triggered): serve-zaino workflow

Key insight: ArgoCD is right for persistent deploys, Argo Workflows + Events for ephemeral ones. AppSets and Workflows aren't mutually exclusive but the snapshot orchestration makes pure AppSets insufficient.

## DNS fix

Tailscale MagicDNS was broken — systemd-resolved was disabled and NetworkManager was overwriting /etc/resolv.conf. Fixed by enabling systemd-resolved and setting `dns=systemd-resolved` in NM config.
