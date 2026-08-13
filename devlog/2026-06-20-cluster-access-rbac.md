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

---

# 2026-06-20 — Golden deployment recovery and version pinning

## Stale volume mount on tekau

Golden-mainnet zebra-0 was stuck in `Init:0/1` for 45+ hours. Root cause: the TopoLVM LV (`3229f53b-...`) was manually mounted read-only at `/mnt/zebra-seed-src` on node `tekau` (likely left over from seeding chain data). Kubelet's CSI mount failed with "already mounted or mount point busy". Other deployments were unaffected because they use fresh LVs — this was specific to the one volume.

Fix: `sudo umount /mnt/zebra-seed-src` on tekau, kubelet retried and succeeded.

## Zaino 0.4.1 incompatible with zebra 5.2.0

Once zebra came up on 5.2.0, zaino crashed with:

```
ValidatorConnectionError(UnrecoverableError(BlockchainSourceError(
  Unrecoverable("parse error: invalid consensus branch id"))))
```

Zaino 0.4.1 doesn't recognize a consensus branch ID introduced in zebra 5.2.0 (likely a new network upgrade). Pinned golden deployments to zebra 5.1.0 for now.

## Built 0.4.1-no-tls-with-prometheus image

The `0.4.1-no-tls` tag existed but there was no variant with prometheus metrics. Used the `build-zaino` Argo WorkflowTemplate to build from the `0.4.1` git tag with `CARGO_FEATURES=no_tls_with_prometheus`. The workflow auto-resolved the tag to `0.4.1-no-tls-with-prometheus` and pushed to Docker Hub.

## Golden config brought to parity with ephemeral deployments

Golden deployments were missing observability config that ephemeral deployments already had:
- `ZAINOLOG_FORMAT=json` + `ZAINOLOG_COLOR=false` for structured Grafana-queryable logs
- `RUST_LOG=zaino=trace` for full log coverage
- `ZAINO_METRICS_ENDPOINT=0.0.0.0:9998` for Prometheus scraping
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.monitoring.svc:4317` for tracing

## Final golden versions

| Component | Image |
|---|---|
| zebra | `zfnd/zebra:5.1.0` |
| zaino | `zingodevops/zaino:0.4.1-no-tls-with-prometheus` |

---

# 2026-06-20 — Tailscale Funnel for Grafana public dashboards

## Goal

Expose specific Grafana dashboards publicly without opening the whole Grafana instance or requiring Tailscale membership.

## Approach: Tailscale Funnel + Grafana Public Dashboards

Grafana 11.x (shipped with kube-prometheus-stack v82.13.6, grafana subchart 11.3.4) has Public Dashboards as a GA feature — no feature toggle needed. Each dashboard can be individually toggled public, producing a unique `/public-dashboards/<uid>` URL that requires no auth. Everything else still requires login.

Tailscale Funnel exposes a service to the public internet via the Tailscale proxy, with TLS termination handled automatically.

## Changes

**Funnel ingress** (`values.yaml`) — added Tailscale Ingress alongside the existing `tailscale.com/expose` service annotation. The service annotation preserves tailnet-only admin access; the ingress adds public Funnel access. Updated `server.domain` and `root_url` to `grafana.vaquita-altair.ts.net` with HTTPS (Funnel terminates TLS).

**Golden Deployments dashboard** (`dashboards/golden-status.yaml`) — new dashboard purpose-built for public sharing. Hardcodes `golden-mainnet` and `golden-testnet` namespaces (no template variables that could leak other namespace names). Panels: Zebra version, peers, Zebra height, Zaino height, chain tip, sync gap, sync progress timeseries, sync rate. Mirrored for both networks. Set `editable: false`, 30s refresh, 6h default window.

## Verification

- `helm template` render confirmed both the Ingress resource and ConfigMap are valid
- Server-side dry-run (`kubectl apply --dry-run=server`) passed clean for both
- Ingress came up with address `grafana.vaquita-altair.ts.net` and a new Tailscale proxy pod (`ts-kube-prometheus-stack-grafana-r9zrh-0`)

## Prerequisites

Tailnet ACL must have `funnel` attribute on the operator's tag (e.g., `"nodeAttrs": [{"target": ["tag:k8s-operator"], "attr": ["funnel"]}]`). Without this, the ingress creates but Funnel won't activate.

## Next steps

- Toggle public sharing on the Golden Deployments dashboard via Grafana UI
- Share the resulting `https://grafana.vaquita-altair.ts.net/public-dashboards/<uid>` link

---

# 2026-06-23 — Deployments, Headlamp, evictions, log retention

## Deployed PR 1274 (`pr-1274-390fd2ad`)

Full ephemeral deploy from branch `pr-1274-390fd2ad` (feature-gate-functional). Built image via `deploy-ephemeral` workflow with default settings.

## Headlamp dashboard

Added Headlamp (v0.43.0) as a platform component via the standard ApplicationSet pattern:
- `platform/defs/headlamp.yaml` + `platform/headlamp/{kustomization,values}.yaml`
- Exposed via Tailscale (`headlamp.<tailnet>.ts.net`)
- Auth disabled via `unsafeUseServiceAccountToken: true` — tailnet is the auth boundary
- Bound to `view` ClusterRole (read-only, no actuation from the UI)

Note: Headlamp's UI still shows edit buttons even with `view` role — the API calls just fail with 403. The UI doesn't hide controls based on RBAC.

## PR 1263 status check and redeployment

Inspected the existing `preview-1263-8f4c234-{2g,8g}` deployments (batch size 2 vs 8):
- Both crashed during initial bulk sync with the same LMDB assertion failure: `Assertion 'IS_BRANCH(mc->mc_pg[mc->mc_top])' failed in mdb_cursor_sibling()` → SIGSEGV (exit code 139)
- 2g variant: 2 restarts; 8g variant: 4 restarts (larger batch = more exposure to the bug)
- Both recovered and were tracking chain tip at height ~3,388,069 — stable for ~3 days post-crash

PR 1263 had 3 new commits since `8f4c234` (head now `26c20744`): accumulator sharding for low-memory systems, separated batch/accumulator size configs, better error logging in initial spent scan. Deployed both variants:
- `preview-1263-26c20744-2g` (SYNC_WRITE_BATCH_SIZE=2)
- `preview-1263-26c20744-8g` (SYNC_WRITE_BATCH_SIZE=8)

## Storage evictions

Cluster was storage-full — new deploys stuck Pending. Evicted 3 namespaces (1.35TiB freed):
- `preview-1238-1f06894` (PR 1238, 6 days old)
- `preview-1263-8f4c234-2g` (old 1263 commit, superseded)
- `preview-1263-8f4c234-8g` (old 1263 commit, superseded)

## Loki log retention bumped to 90 days

Investigated Loki storage: only ~850Mi used on a 50Gi PVC for 14 days of logs. Bumped `retention_period` from 336h (14d) to 2160h (90d). At current ingest rates, 90 days should use ~5-6Gi — well within headroom. Logs from deleted ephemeral namespaces now stay queryable in Grafana for 3 months.

Also noted an orphaned PVC `storage-loki-stack-0` (50Gi) from the old loki-stack install — candidate for reclamation.

---

# 2026-08-13 — New collaborator (elicbarbieri) + imperative tooling vs ArgoCD

## Access grant

Added collaborator `elicbarbieri` to the `cluster-access` chart with **cluster-wide built-in `edit`** (one-line `values.yaml` entry, `role: edit`). This is the "operator, slightly less than owner" tier: create/update/delete workloads, scale, exec, port-forward, read/write configmaps and secrets — but **cannot** touch RBAC, resource quotas, or nodes. Chose `edit` over a bespoke ClusterRole for zero RBAC maintenance.

`edit` aggregates `view`, so `pods/log` is included — no separate `logs: true` needed. Renders as SA `elicbarbieri` + Secret `elicbarbieri-token` + ClusterRoleBinding `elicbarbieri-edit`.

**Trust note:** cluster-wide `edit` reads *every* Secret in the cluster (sealed-secrets master, authentik OAuth, deploy tokens). Accepted for this collaborator. If tighter isolation is ever wanted, options are (a) namespace-scoped binding, or (b) a custom operate role (view + exec/port-forward/pod-delete + Argo submit, no secret read).

## Question that drove the design: imperative manifest tool vs ArgoCD

Collaborator wants to run an imperative tool that deploys a bunch of manifests. **Verdict: fully compatible**, with one rule.

Key fact: an ArgoCD Application only owns the resources it *renders from its git `sourcePath`* (tracked via ArgoCD's tracking label). Even though both ApplicationSets run `prune: true` + `selfHeal: true` (`clusters/production/appset.yaml`), that only affects each app's own tracked set:
- **selfHeal** reverts drift on objects ArgoCD manages
- **prune** deletes objects removed from git *within that app's tracked set*
- **untracked objects are never touched** — even in a namespace an ArgoCD app also uses

Precedent already in the cluster: the entire ephemeral preview system is an imperative deployer (Argo **Workflows**, not ArgoCD) stamping zaino+zebra stacks into `preview-*` namespaces that **no def claims**. ArgoCD ignores them.

**The rule:** point the imperative tool at namespace(s) **not matched by any `platform/defs/*.yaml` or `domain/defs/*.yaml`** entry → zero conflict. Modifying objects ArgoCD renders (or colliding on name/kind) is the only thing that triggers a selfHeal fight.

Caveat: RBAC doesn't enforce this — cluster-wide `edit` can deploy into managed namespaces too, so "stay out of ArgoCD's namespaces" is convention, not a guardrail. Enforcing it would require namespace-scoping the binding.

## Next steps

- Commit + let ArgoCD sync `cluster-access`
- `scripts/extract-kubeconfig.sh elicbarbieri` → send kubeconfig + Tailscale invite (tailnet access required to reach the API server)
