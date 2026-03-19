# Session Notes: 2026-03-19

## Findings

### ArgoCD repo-server crash
- **Cause:** Pod sandbox changed (node restart?), emptyDir volumes retained stale data
- **Symptom:** `copyutil` init container failed with `/bin/ln: Already exists`
- **Fix:** Delete pod to get fresh emptyDir volumes

### Kanister dynamic dependency limitation
- Kanister blueprints operate on single-resource-per-ActionSet model
- Cannot dynamically discover "all StatefulSets with label X"
- Cannot iterate over discovered resources
- External orchestration (Argo Workflows, pre-backup Jobs) would be needed for dependent quiescing

## Decisions

### ArgoCD sync options for operator + CR pattern
- **Decision:** Use both `sync-wave` AND `SkipDryRunOnMissingResource=true` for Kanister app
- **Context:** Blueprint CRD is installed by Helm chart, but Blueprint resource is in same kustomization
- **Problem:** ArgoCD validates ALL resources before applying ANY. Validation fails because CRD doesn't exist yet.
- **Why sync-waves alone don't work:** Waves control application ORDER, but validation happens BEFORE any application
- **Solution:**
  - `sync-wave: "1"` on Blueprint → applies after Helm chart
  - `SkipDryRunOnMissingResource=true` → skips validation for resources with missing CRDs
- **Trade-off:** Typos in Blueprint won't be caught until wave 1 applies (minor - errors show immediately)
- **ADR candidate:** Yes - this is a reusable pattern for any operator + CR deployment

### Zaino handling during zebra snapshots
- **Decision:** Let zaino ride out brief zebra downtime during snapshots
- **Rationale:** LVM thinpool snapshots are sub-second (metadata-only COW), doesn't justify orchestration complexity
- **Risk accepted:** Relies on zaino resilience to brief zebra unavailability
- **Note:** If zaino proves fragile, fix zaino rather than add orchestration complexity
- **ADR candidate:** Yes - document this decision formally

### Kanister RBAC requirements
- **Finding:** Default Kanister Helm chart RBAC only covers `cr.kanister.io` CRDs
- **Problem:** Kanister can't scale workloads or create snapshots in other namespaces
- **Research:** Kanister removed `edit` ClusterRole due to security advisory GHSA-h27c-6xm3-mcqp
- **Official recommendation:** Use RoleBinding per namespace (not ClusterRoleBinding)
- **Solution:**
  - ClusterRole `kanister-workload-manager` defines permissions once
  - RoleBinding in each namespace grants access (currently: `zcash`)
- **Permissions granted:**
  - `apps` StatefulSets/Deployments: get, list, watch, patch, update
  - `snapshot.storage.k8s.io` VolumeSnapshots: get, list, watch, create, delete
  - Core PVCs and Pods: get, list, watch
- **To add new namespace:** Add another RoleBinding in rbac.yaml

### Snapshot workflow test
- **Result:** SUCCESS
- Kanister ActionSet completed in ~30 seconds
- VolumeSnapshots created with `READYTOUSE: true`
- Zebra scaled 1→0→1, zaino reconnected after brief outage
- Zaino had 5 restarts during zebra downtime (expected behavior)

## TODO for devlog
- [ ] Document Kanister limitation finding
- [ ] Document zaino-during-snapshot decision (ADR?)
- [ ] Any other insights from today's session
