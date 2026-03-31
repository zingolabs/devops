# Serve-Zaino Workflows & Storage Resize

Date: 2026-03-30

## Goal

Build an end-to-end workflow to deploy arbitrary zaino refs for developers,
and right-size the storage allocations that were exhausting the thin pool.

## Serve-zaino lifecycle workflows

Created three single-purpose workflows (caller decides which to invoke):

- **`serve-zaino`** — First deploy: build image + fresh Kanister snapshot (parallel)
  → create namespace → clone snapshot → helm install. For PR opened / manual deploy.
- **`update-zaino`** — Update existing deploy: build image → helm upgrade (just swaps
  the image tag). No snapshot needed — existing PVC has synced state. For PR push.
- **`cleanup-ephemeral`** — Teardown: delete VolumeSnapshotContents referencing the
  namespace (safe with Retain policy — only removes K8s object, not LVM data), then
  delete namespace. For PR closed.

Design decision: separate workflows rather than one smart workflow that detects state.
This maps cleanly to Argo Events triggers and keeps each workflow simple.

## build-zaino made composable

Refactored `build-zaino` templates to use `inputs.parameters` with literal defaults
instead of `workflow.parameters` references. Now works both standalone (`argo submit`)
and via `templateRef` from other workflows like `serve-zaino`.

## Zaino Kanister blueprint

Created separate `zaino` Kanister blueprint (split from `zcash-stack`). Handles
zaino-only backup/restore/delete lifecycle. Used by `serve-zaino` for on-demand
fresh snapshots without touching zebra.

## Storage crisis and PVC resize

### Problem discovered
The topolvm thin pool (1.7TB) was exhausted by overprovisioned PVCs:
- Golden mainnet: zaino 500Gi (actual: 44Gi), zebra 400Gi (actual: 257Gi)
- Each ephemeral deploy cloned 500Gi zaino PVCs
- 9 orphaned snapshot LVs at 500Gi each from serve-zaino testing
- Total logical allocation: ~7TB on a 1.7TB pool

Topolvm uses the **logical** size for overprovisioning checks, not physical.
So even though thin snapshots use minimal physical space (CoW deltas), each
500Gi snapshot counts as 500Gi towards capacity.

### Key learnings about topolvm/LVM thin storage
- **VolumeSnapshotContent with deletionPolicy: Retain**: deleting the VSC does NOT
  delete the underlying LVM snapshot (confirmed via snapshot-controller source code).
  Must patch to `Delete` policy first, then delete, for CSI to call DeleteSnapshot.
- **PV/LV finalizer deadlocks**: can't delete parent LV while snapshots exist,
  can't delete snapshots while parent is terminating. Break with finalizer removal.
- **StatefulSet volumeClaimTemplates are immutable**: can't resize in-place via
  ArgoCD. Must disable → delete → re-enable cycle through git commits.
- **PVCs survive StatefulSet deletion**: Kubernetes doesn't GC PVCs created by
  volumeClaimTemplates. Must delete explicitly.
- **/mnt bind mounts are stale after PVC recreation**: the convenience mounts on
  tekau (/mnt/mainnet-zebra etc) point to old LV UUIDs. After PVC recreation,
  must rsync to the new kubelet mount paths or manually mount the new LVs.

### Resize procedure (3 git commits)
1. `enabled: false` for both zebra and zaino → ArgoCD prunes all resources
2. Delete orphaned PVCs manually (ArgoCD doesn't manage PVC lifecycle)
3. `enabled: true` with new sizes → ArgoCD creates fresh StatefulSets + PVCs
4. Restore data from rsync backup on nvme0n1

### New allocations
| Volume | Before | After | Actual usage |
|---|---|---|---|
| Golden mainnet zebra | 400Gi | 350Gi | 257Gi |
| Golden mainnet zaino | 500Gi | 100Gi | 44Gi |
| Golden testnet zaino | 200Gi | 100Gi | 18Gi |
| Ephemeral zaino | 500Gi | 100Gi | ~44Gi |

## TODO (next session)
- Deploy PR 934 with serve-zaino (now that pool has space)
- Storage management plan: automatic snapshot pruning, capacity monitoring
- Argo Events setup for GitHub PR label triggers
- Storage report script (proper visibility into PVCs/LVs/snapshots)
- Update /mnt bind mounts on tekau to point to new LVs
- Consider: CronWorkflow for regular golden snapshots with pruning

## Helm --wait vs zaino readiness (discovered during tracing work)

The `--wait` flag on helm install/upgrade blocks until the pod is Ready.
Zaino's readiness probe (TCP 8137) only passes after the gRPC server starts,
which only happens after initial sync completes. This causes cascading issues:

1. **serve-zaino with use-cache=false**: helm-install blocks for 10 minutes
   then times out. The pod is running and syncing correctly but helm reports failure.
2. **update-zaino after serve-zaino**: helm locks the release during `--wait`.
   If serve-zaino's helm-install is still waiting, update-zaino gets
   "another operation is in progress" and fails.
3. **Rolling updates blocked**: `kubectl rollout restart` on a StatefulSet won't
   terminate the old pod until the new one is Ready. Since the pod is never Ready
   during sync, the rollout hangs.

Root cause: zaino doesn't open port 8137 until after initial sync. Kubernetes
and helm have no signal that zaino started correctly but is still syncing.
See zaino-design/zaino-observability-requirements.md for the full analysis.

Workaround: removed `--wait` from update-zaino. serve-zaino still uses `--wait`
which works for cached deploys (fast sync) but times out on fresh deploys.

## Loki upgrade 2.6→3.x

Upgraded from deprecated loki-stack chart (2.10.3, Loki 2.6.1) to standalone
loki chart (6.55.0, Loki 3.6.7) + promtail chart (6.17.1). Enables:
- `volume_enabled` for Grafana Logs Drilldown
- `pattern_ingester` for pattern matching in Drilldown
- TSDB index (v13) with structured metadata support
- `allow_structured_metadata` for JSON field extraction

Fresh PVC (storage format incompatible between 2.x and 3.x). 14 days of old
logs lost but they would have expired anyway.

## Structured tracing work (feature/structured-tracing branch on zaino)

Started improving zaino's tracing instrumentation. Key changes:
- `write_core` block commit log: extracted `height` and `block_hash` as
  structured tracing fields instead of baking into message string
- `BlockHash` Display: now shows first 8 + last 8 hex chars (`00000000..5fe11b69`)
  instead of just first 8 (`00000000..`) which was always identical due to PoW zeros
- Set `zaino=trace,zainod=trace,info` as default log level for ephemeral deploys

JSON structured logging (`ZAINOLOG_FORMAT=json`) combined with Loki 3.x means
all tracing fields are queryable in Grafana without regex.

## OpenTelemetry + Tempo

Deployed Grafana Tempo (2.9.0 single-binary) for distributed tracing. Added
`tracing-opentelemetry` + `opentelemetry-otlp` to zaino (behind `otel` feature
flag, default on). When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, spans are exported
to Tempo via OTLP gRPC. Existing `#[instrument]` annotations work unchanged.

Grafana datasource configured with bidirectional Loki↔Tempo linking:
- Log line → click "View Trace" → flame graph in Tempo
- Trace span → click "Logs" → Loki filtered by trace ID

Tempo metrics-generator OOMKills at high trace volume during bulk sync.
Increased to 4Gi, may need sampling or tuning for sustained bulk sync loads.

## Batched sync architecture

Changed the sync loop from "sync entire chain in one `sync_to_height` call" to
bounded 1000-block batches per iteration. Each `sync_iteration` span completes
in seconds, exports to Tempo immediately, and emits a structured batch summary:

```json
{"message":"Syncing batch","from_height":1785000,"to_height":1786000,
 "blocks_to_sync":1000,"chain_tip":3291050,"blocks_remaining":1505050,
 "progress_pct":54}
```

Previous approach: one `sync_to_height` call processing 1.5M+ blocks, span never
closed, no metrics/traces exported until complete (hours).

## NFS sync boundary issue

Discovered that NonFinalizedState (designed for ~100 block tip window) was being
asked to sync 1.5M+ blocks during bulk sync. The sync loop passes NFS the entire
gap between finalized tip and chain tip.

Added a guard: NFS skips sync when gap exceeds 100 blocks and logs a warning.
Proper fix documented in zaino-design/nfs-sync-boundary.md — NFS should receive
an explicit bounded window, not "sync everything FS didn't".

## ZainoDB status flapping fix

Removed per-block `StatusType::Ready` / `StatusType::Syncing` transitions from
`write_core`. Status was flipping thousands of times per second during bulk sync.
Status lifecycle (Syncing → Ready) is now owned by the db handler, not individual
block writes. Also fixed a bug where `CriticalError` was immediately overwritten
by `RecoverableError` on the same line.

## zcash-stack chart: extraEnv

Added `extraEnv` passthrough to the zaino container in the zcash-stack helm chart.
Operators can now pass arbitrary env vars (e.g. OTEL_EXPORTER_OTLP_ENDPOINT)
without modifying the chart template for each new variable.

## Design docs created
- `zaino-design/zaino-observability-requirements.md` — health/readiness/metrics from operator POV
- `zaino-design/local-dev-environment.md` — k3d lightweight cluster for zaino dev iteration
- `zaino-design/nfs-sync-boundary.md` — NFS architecture fix for bounded sync window

## TODO (next session)
- Clean up feature/structured-tracing branch into reviewable PRs
- Argo Events for GitHub PR label → workflow triggers
- Storage management: snapshot pruning, capacity monitoring
- Tempo metrics-generator tuning (sampling for bulk sync)
- NFS architecture: explicit bounded window, decouple from FS
- Zaino health/readiness probes: start gRPC server before sync
- Local k3d dev environment for fast tracing iteration
