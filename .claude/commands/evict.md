Scout stale ephemeral deployments and evict them to reclaim LVM thin pool storage.

Each ephemeral mainnet deploy consumes ~450Gi (350Gi zebra + 100Gi zaino), testnet ~120Gi.
The LVM thin pool has finite capacity and old deployments cause new ones to get stuck in Pending.

## Steps

### 1. List ephemeral namespaces with age and ref

Run this to get all ephemeral namespaces with their creation time and labels:

```bash
kubectl get ns -l zcash-stack/ephemeral=true --context zingo-infra \
  -o custom-columns='NAMESPACE:.metadata.name,AGE:.metadata.creationTimestamp,NETWORK:.metadata.labels.zcash-stack/network,REF:.metadata.labels.zcash-stack/ref' \
  --sort-by=.metadata.creationTimestamp
```

### 2. Check pod status in each namespace

For each namespace, check if pods are actually running or stuck:

```bash
kubectl get pods -n <namespace> --context zingo-infra -o wide
```

### 3. Get storage overview

Run the storage report script for a cluster-wide view:

```bash
./scripts/storage-report.sh
```

For deeper LVM thin pool stats (requires SSH to node):

```bash
./scripts/storage-report.sh --ssh pua@tekau
```

### 4. Present eviction candidates

Present a table to the user sorted by age (oldest first), showing:
- Namespace name
- Age (human-readable, e.g. "12d", "3d")
- Network (mainnet/testnet)
- Ref label (what was deployed)
- Pod status (Running/Pending/CrashLoop/None)
- Estimated storage (450Gi mainnet, 120Gi testnet, 100Gi tryout)

Recommend eviction candidates based on:
- **Oldest first** — deployments older than 7 days are strong candidates
- **Non-running pods** — stuck/crashed deployments are wasting space
- **No recent activity** — pods in CrashLoopBackOff or completed

### 5. Evict selected namespaces

After user confirms which namespaces to evict, run cleanup for each:

```bash
argo submit --from workflowtemplate/cleanup-ephemeral -n argo \
  -p namespace=<namespace> --context zingo-infra
```

Wait for each cleanup to complete before starting the next (they touch cluster-scoped VSCs):

```bash
argo watch -n argo <workflow-name> --context zingo-infra
```

### 6. Verify reclaimed space

After evictions complete, run the storage report again to confirm space was reclaimed.

## Important notes

- Only namespaces labeled `zcash-stack/ephemeral=true` can be cleaned up (safety check in the workflow)
- Cleanup reaps Tailscale devices if expose-public was used
- VolumeSnapshotContent with `deletionPolicy: Retain` only removes the K8s object, not the underlying LVM snapshot — this is by design (golden snapshots are shared)
- If a namespace is stuck in Terminating, check for finalizer deadlocks on VolumeSnapshots
- Always confirm with user before evicting — never auto-delete

$ARGUMENTS
Optional: "list" to just show status, or namespace names to evict directly.
