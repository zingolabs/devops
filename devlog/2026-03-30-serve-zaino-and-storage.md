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
