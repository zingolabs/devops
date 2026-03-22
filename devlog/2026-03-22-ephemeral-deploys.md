# 2026-03-22: Ephemeral Deploys from Snapshots

## Summary

Successfully implemented cross-namespace snapshot restore for ephemeral test deployments. Validated CoW storage efficiency and RocksDB lock bypass.

## Key Achievements

### Cross-Namespace VolumeSnapshot Cloning

**Problem:** VolumeSnapshots are namespace-scoped, but we need to restore snapshots from `zcash` namespace into isolated `ephemeral-test` namespaces.

**Solution:** Manual VolumeSnapshotContent pattern (production-ready, no alpha features):
1. Get `snapshotHandle` from source VolumeSnapshotContent (cluster-scoped)
2. Create new VolumeSnapshotContent pointing to same handle, with `volumeSnapshotRef` to target namespace
3. Create VolumeSnapshot in target namespace referencing the new content
4. PVCs can then use that snapshot as dataSource

**Alternatives considered:**
- Native `CrossNamespaceVolumeDataSource` - still alpha in K8s 1.30, requires feature gates
- Velero - overkill for this use case, adds operational complexity
- Deploy to same namespace - defeats isolation purpose

### Storage Efficiency Validated

Thin provisioning + CoW snapshots working as expected:

| Metric | Value |
|--------|-------|
| Thin pool size | 900Gi |
| Provisioned (logical) | ~1130Gi |
| Actual used | ~122Gi (14%) |

Ephemeral PVs share blocks with source snapshots. Only divergent writes consume new space.

### RocksDB Lock Bypass Confirmed

Ran both golden and ephemeral zebra instances simultaneously:
- Golden: `zcash/zebra-testnet-0` at height 2.1M
- Ephemeral: `ephemeral-test/zebra-0` at height 876k (from snapshot)

No lock conflicts. Each instance has its own thin LV clone with its own filesystem mount. CoW sharing happens at block device layer, invisible to RocksDB.

## Current Workflow State

`deploy-ephemeral` WorkflowTemplate:
- ✅ Creates isolated namespace with ephemeral label
- ✅ Clones snapshots cross-namespace (parallel for zebra + zaino)
- ✅ Deploys zcash-stack via helm from git
- ✅ Reports endpoints on completion
- ❌ Hardcoded snapshot names (needs CLI for dynamic selection)
- ❌ No GitHub integration
- ❌ No test execution
- ❌ No reporting back to GitHub

## What's Missing for Production Use

### 1. Dynamic Snapshot Selection
CLI tool should query "latest golden snapshot for testnet" instead of hardcoded names.

### 2. GitHub Event Trigger
```
GitHub PR opened → Argo Events → deploy-ephemeral workflow
```

### 3. Test Execution Step
After deploy, actually run something:
- Wallet sync test against zaino
- RPC compatibility checks
- Integration test suite
- Performance benchmarks

### 4. GitHub Feedback Loop
- Create GitHub Deployment (shows in PR)
- Update deployment status (pending → in_progress → success/failure)
- Post comments with results
- Link to logs

### 5. Cleanup
TTL-based or explicit cleanup after test completes.

**The value proposition:**
```
PR opened → deploy ephemeral stack from snapshot → run test suite → report pass/fail to PR → cleanup
```

Without test execution and GitHub integration, it's just a fancy way to spin up infrastructure that sits there.

## Open Questions for Next Session

### Observability Infrastructure
- Would logs/metrics capturing add value to ephemeral deploys?
- Could help debug test failures, capture performance baselines
- Options: Loki/Promtail, Victoria Metrics, lightweight alternatives
- Trade-off: complexity vs debugging capability

### Tailscale Kubernetes Operator
- Could expose services from cluster without manual port-forwarding
- No need for `kubectl port-forward` or `serve` configs
- Each ephemeral deploy could get its own tailnet hostname?
- Research: What does the operator actually provide?

## Files Changed

- `platform/argo-workflows/workflows/deploy-ephemeral.yaml` - Added clone-snapshot step
- `platform/argo-workflows/workflows/ephemeral-values.yaml` - ConfigMap for testnet values
- `platform/argo-workflows/workflows/rbac.yaml` - Added VolumeSnapshotContent permissions

## Commands Reference

```bash
# Submit ephemeral deploy
kubectl -n argo create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: deploy-ephemeral-
spec:
  workflowTemplateRef:
    name: deploy-ephemeral
  arguments:
    parameters:
      - name: namespace
        value: ephemeral-test
      - name: zebra-snapshot
        value: zebra-testnet-data-zebra-testnet-0-snapshot-dqrkh
      - name: zaino-snapshot
        value: data-zaino-testnet-0-snapshot-ms8jh
EOF

# Cleanup
kubectl -n argo create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: cleanup-ephemeral-
spec:
  workflowTemplateRef:
    name: cleanup-ephemeral
  arguments:
    parameters:
      - name: namespace
        value: ephemeral-test
EOF

# Check thin pool usage
sudo lvs --units g -o lv_name,lv_size,data_percent,pool_lv
```

## Priority for Next Session

1. **GitHub integration** (Argo Events + GitHub Deployments API) - makes it triggerable and visible
2. **CLI for dynamic snapshot selection** - removes hardcoding
3. **Test execution step** - makes it actually validate something
