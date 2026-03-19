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

## TODO for devlog
- [ ] Document Kanister limitation finding
- [ ] Document zaino-during-snapshot decision (ADR?)
- [ ] Any other insights from today's session
