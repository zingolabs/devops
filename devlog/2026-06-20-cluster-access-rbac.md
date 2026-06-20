# 2026-06-20 — GitOps cluster access for external viewers

## Problem

Needed to give zancas read-only k9s/kubectl access to the cluster without sharing admin credentials or creating one-off resources imperatively.

## Solution

Created a reusable Helm chart at `platform/cluster-access/` that generates per-user RBAC from a single `values.yaml` list. ArgoCD manages it like any other platform app — the ApplicationSet auto-detects the Chart.yaml and renders it as Helm.

Each user entry produces:
- ServiceAccount + long-lived token Secret (in `default` namespace)
- ClusterRoleBinding to the built-in `view` ClusterRole (or namespace-scoped RoleBindings)
- Optional `pods/log` ClusterRole + binding (`logs: true`)

Adding/removing a user is a one-line values.yaml change. Revocation is automatic via ArgoCD prune.

## Kubeconfig extraction

The one imperative step: `scripts/extract-kubeconfig.sh <username>` reads the synced token and cluster CA from the live cluster and writes a standalone kubeconfig file. The recipient also needs Tailscale access to reach the API server.

## First user: zancas

Added with cluster-wide `view` + `logs` access. Kubeconfig generated and verified working.

## Next steps

Exploring the Tailscale Kubernetes operator as a potential upgrade path — it can map Tailscale identities directly to k8s RBAC, eliminating token management entirely.

---

# 2026-06-20 — Metrics dashboards, crash forensics, and crash report dashboard

## Metrics deployment

Deployed `feature/rc-metrics-support` (commit 8f4c234) via `deploy-ephemeral` workflow. Zaino now exposes 8 Prometheus metrics on `:9998/metrics` — 3 gauges (chain tip, finalized height, target height), 3 counters (transactions, sapling outputs, orchard actions), 2 summaries (block build latency, block write latency).

Cleaned up 4 old ephemeral deployments (bisect-1207, bisect-1214, trial-metrics, preview-hotpath) to free ~1.8 TiB of storage.

## New Grafana dashboards

**Zcash Stack** (`zcash-stack`) — unified time-based operational dashboard for zebra + zaino. Info bar with version/peers/heights/sync gap, chain sync progress with combined zebra+zaino+tip lines, zebra RPC request rate and latency by method, zaino throughput (tx/s, shielded actions/s), block build/write latency percentiles.

**Sync Profile** (`sync-profile`) — XY charts plotting metrics as a function of block height instead of time. Sync speed, TX throughput, shielded throughput (sapling vs orchard), block build latency (log10), RPC latency by method (log10). All as scatter plots (points, not lines — height can go backwards on reorg/rollback). Tables below latency charts showing current quantile values.

## Crash investigation — LMDB assertion, not OOM

Deployed two instances of PR 1263 (`preview-1263-8f4c234-2g` and `preview-1263-8f4c234-8g`). Initially assumed crashes were OOMKilled based on experience with `rc-metrics-4fa732f6` (which genuinely OOMs at 16Gi with 142 restarts).

**Key finding**: the 1263 pods exit with code 139 (SIGSEGV), reason "Error" — not OOMKilled. The last log line before each crash is:

```
lmdb-sys-0.8.0/lmdb/libraries/liblmdb:5800: Assertion 'IS_BRANCH(mc->mc_pg[mc->mc_top])' failed in mdb_cursor_sibling()
```

This is an LMDB B-tree corruption — the C library calls `abort()` directly, bypassing Rust's logger. The assertion message goes to stderr, which containerd captures (visible via `kubectl logs --previous`), but it's not a structured JSON log line. Zaino has no Rust-level error handling for this path.

The 8g namespace logs showed what appeared to be 3 concurrent write streams targeting different heights, which may be related to the corruption.

**Both configs are identical** — same image, same `zaino.toml`, same env vars, same K8s limits (16Gi). The "2g"/"8g" naming was misleading; no actual RAM cap differentiation was applied.

### Fleet-wide crash inventory

| Namespace | Restarts | Reason | Exit Code |
|---|---|---|---|
| rc-metrics-4fa732f6 | 142 | OOMKilled | 137 |
| preview-1238-1f06894 | 133 | OOMKilled | 137 |
| preview-050-rc1 | 210 | Error | 1 |
| preview-1263-8f4c234-2g | 2 | Error | 139 (SIGSEGV) |
| preview-1263-8f4c234-8g | 4 | Error | 139 (SIGSEGV) |
| preview-1242-b9adb68 | 0 | — | — |

Three distinct failure modes: OOM (137), LMDB assertion (139), app error (1).

## Crash Report dashboard

Built `crash-report` dashboard to make crash forensics self-service:

- **Stats bar**: crash looping count, OOMKilled count, non-OOM error count, total restarts
- **Fleet status table**: all zaino/zebra pods sorted by restart count, with termination reason, color-coded severity
- **Restart timeline**: scatter plot of restart events over time per namespace/container
- **Memory at termination**: container memory usage vs K8s limits — spikes before restarts indicate OOM pressure
- **Loki crash logs**: filters for `assertion.*failed`, `panic`, `SIGSEGV`, `mdb_`, `OOM` — catches both structured and raw stderr
- **Loki warning logs**: `WARN`-level structured lines (sync retry failures that precede crashes)

Added restart annotation markers (red vertical lines) to zcash-stack (zaino + zebra) and sync-profile (zaino) dashboards.

## Insights

- Kubernetes only stores `lastState` — earlier crash reasons are lost. This is why the crash report dashboard with Prometheus time-series is valuable: `kube_pod_container_status_restarts_total` preserves the restart count over time even though the reason for each individual restart isn't retained.
- `kubectl logs --previous` captures stderr including raw C assertion messages, but these aren't queryable in structured log pipelines unless you grep for the raw text via Loki.
- The LMDB assertion is an upstream zaino bug — the concurrent write streams visible in logs suggest a transaction/locking issue. Worth filing.
