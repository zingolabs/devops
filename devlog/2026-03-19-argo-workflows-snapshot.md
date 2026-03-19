# 2026-03-19: Argo Workflows Snapshot Orchestration

Implementing automated snapshot workflow with metadata labeling using Argo Workflows + Kanister.

## Starting State

- Kanister: deployed with working blueprint for coordinated zebra+zaino snapshots
- TopoLVM: thinpool snapshots working
- Missing: orchestration layer for metrics collection, snapshot triggering, and labeling

## Goal

Automated workflow that:
1. Queries zebra for current height/version
2. Triggers Kanister snapshot
3. Labels VolumeSnapshots with metadata
4. Rotates "latest" label

---

## Decisions

### Orchestration Layer: Argo Workflows

**Options considered:**
- CronJob + bash script
- Tekton
- Argo Workflows

**Decision:** Argo Workflows

**Rationale:**
- GitOps-native (WorkflowTemplates are CRDs, managed by ArgoCD)
- Visual step debugging when failures occur
- Reusable templates for multiple workflows
- DAG support for complex flows (export-to-r2 will need this)

### Label Semantics

```
zcash-stack/source=golden     # vs ephemeral for RC deploys
zcash-stack/latest=true       # auto-rotated by workflow
zcash-stack/promoted=true     # manually set for R2 distribution
zcash-stack/height=854800
zcash-stack/zebra-version=4.0.0
zcash-stack/timestamp=2026-03-19_214058Z
```

### Metrics Timing

Query zebra metrics BEFORE quiesce (not after). Window is milliseconds, acceptable accuracy. No ephemeral pod needed.

---

## Implementation

### Workflow: snapshot-golden

```
Steps:
1. get-metrics      → curl zebra:8080, extract height+version
2. create-snapshot  → create Kanister ActionSet, wait for completion
3. unset-latest     → remove latest=true from previous snapshots
4. label-snapshots  → apply metadata labels to new snapshots
```

Files:
- `platform/argo-workflows/workflows/snapshot-golden.yaml`
- `platform/argo-workflows/workflows/rbac.yaml`

---

## Issues Encountered

### 1. Zebra metrics port not exposed

**Symptom:** Workflow step timed out connecting to zebra:8080

**Root cause:** zcash-stack Helm chart only exposed RPC port in Service, not metrics

**Investigation:**
- ConfigMap had `endpoint_addr = "0.0.0.0:8080"` (metrics configured)
- StatefulSet exposed port 8080 (container listening)
- Service only had port 18232 (RPC)

**Fix:** Added metrics port to `zebra-service.yaml` in zcash-stack chart (upstream)

```yaml
ports:
  - port: 18232
    name: rpc
  - port: 8080      # added
    name: metrics   # added
```

### 2. Argo Workflows RBAC for output parameters

**Symptom:** `workflowtaskresults.argoproj.io is forbidden`

**Root cause:** Workflow steps that emit output parameters need to create `workflowtaskresults` resources

**Fix:** Added to ClusterRole:
```yaml
- apiGroups: ["argoproj.io"]
  resources: ["workflowtaskresults"]
  verbs: ["create", "patch"]
```

Plus RoleBinding in `argo` namespace.

### 3. Kubernetes label timestamp format

**Symptom:** `invalid label value` error

**Root cause:** Labels can't contain colons (`:`)

**Bad:** `2026-03-19T21:04:50Z`
**Good:** `2026-03-19_214050Z`

**Fix:** `date -u +%Y-%m-%d_%H%M%SZ`

---

## Result

Workflow completed successfully:

```
NAME                                                HEIGHT   VERSION   LATEST   TIMESTAMP
data-zaino-testnet-0-snapshot-ms8jh                 854800   4.0.0     true     2026-03-19_214058Z
zebra-testnet-data-zebra-testnet-0-snapshot-dqrkh   854800   4.0.0     true     2026-03-19_214058Z
```

Previous snapshots had `latest` label removed automatically.

---

## Lessons Learned

1. **Check the full stack:** Container listens, StatefulSet exposes, Service routes. All three need alignment.
2. **Argo Workflows RBAC:** Task result reporting is a separate permission from the workflow's actual work
3. **K8s label values:** Strict character requirements - test with real values early

---

## Next Steps

- [ ] Add CronWorkflow trigger (schedule TBD)
- [ ] Create export-to-r2 workflow (tar.zst → sign → upload → manifest)
- [ ] Test restore from labeled snapshot
