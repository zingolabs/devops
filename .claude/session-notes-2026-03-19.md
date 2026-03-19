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
