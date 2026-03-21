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

### Argo Workflows for snapshot orchestration
- **Decision:** Use Argo Workflows as the orchestration layer for snapshot lifecycle
- **Rationale:**
  - Fits GitOps model (WorkflowTemplates are CRDs, managed by ArgoCD)
  - Visual debugging when steps fail
  - Reusable templates for multiple workflows (snapshot, export, restore)
  - Better than CronJob+script for multi-step workflows with shared logic
- **Workflows planned:**
  - `snapshot-golden`: CronWorkflow - metrics → kanister → label
  - `export-to-r2`: Workflow - tar.zst → sign → upload → update manifest
- **Integration:** Deployed as ArgoCD app in platform, workflow definitions in git

### Snapshot metadata timing
- **Decision:** Query zebra metrics BEFORE quiesce (not after)
- **Rationale:** Window between query and snapshot is milliseconds, acceptable accuracy
- **No ephemeral pod needed** - just query running zebra, then scale down

### Dynamic snapshot refs in GitOps
- **Problem:** ArgoCD expects manifests in git, but VolumeSnapshot names are dynamic
- **Research:** No built-in solution - all approaches need external tooling
- **Open question:** What is the source of truth for "latest golden snapshot"?
  - Labels on VolumeSnapshots? (query at runtime)
  - Argo Workflows artifacts?
  - External manifest (R2)?
  - TBD - not yet decided

### Future refactor: Separate deploy definitions from values
- **Issue to create:** Refactor all platform apps to use kustomization + valuesFile pattern
- **Why:** Currently mixing inline values in Application specs (cert-manager, topolvm) with path-based (kanister)
- **Goal:** Consistent pattern across all apps - Application points to path, values live in separate file

### snapshot-golden workflow - End-to-End Success

**Status:** Working

**Fixes applied:**
1. **Zebra metrics port** (upstream fix in `zingolabs/zcash-stack`)
   - Chart only exposed RPC port, not metrics
   - ConfigMap already had `endpoint_addr = "0.0.0.0:8080"` configured
   - StatefulSet exposed port 8080 when probes enabled
   - **Gap:** Service didn't expose the port externally
   - **Fix:** Added metrics port to `zebra-service.yaml` template

2. **Argo Workflows RBAC for output parameters**
   - Workflow steps that emit output parameters need `workflowtaskresults` API access
   - **Error:** `workflowtaskresults.argoproj.io is forbidden`
   - **Fix:** Added to ClusterRole:
     ```yaml
     - apiGroups: ["argoproj.io"]
       resources: ["workflowtaskresults"]
       verbs: ["create", "patch"]
     ```
   - Plus RoleBinding in `argo` namespace

3. **K8s label timestamp format**
   - Labels can't contain colons (`:`)
   - **Bad:** `2026-03-19T21:04:50Z`
   - **Good:** `2026-03-19_214050Z`
   - **Fix:** `date -u +%Y-%m-%d_%H%M%SZ`

**Workflow output verified:**
```
NAME                                                HEIGHT   VERSION   LATEST   TIMESTAMP
data-zaino-testnet-0-snapshot-ms8jh                 854800   4.0.0     true     2026-03-19_214058Z
zebra-testnet-data-zebra-testnet-0-snapshot-dqrkh   854800   4.0.0     true     2026-03-19_214058Z
```

**Lessons learned:**
- Always check what the chart actually exposes vs what the container listens on
- Argo Workflows needs explicit RBAC for task result reporting
- K8s labels have strict character requirements - test with actual values

## TODO for devlog
- [ ] Document Kanister limitation finding
- [ ] Document zaino-during-snapshot decision (ADR?)
- [x] Document snapshot-golden workflow fixes and success
- [ ] Document GitOps repo restructure (ApplicationSet, platform/domain separation)

---

## 2026-03-21: GitOps Repo Restructure

### Problem
- Repetitive Application definitions across clusters (local vs production)
- No clear separation between infrastructure (platform) and workloads (domain)
- Branch-per-environment anti-pattern concerns
- Manual promotion workflow unclear

### Research
- Compared Helm app-of-apps vs ApplicationSets
- Community moving toward ApplicationSets for dynamic workloads
- Standard pattern: directory-per-environment, not branch-per-environment
- Kustomize can wrap Helm charts via `helmCharts` generator

### Decisions

#### Directory structure: `platform/` + `domain/`
```
platform/           # Infrastructure (cert-manager, topolvm, kanister, etc.)
├── defs/           # App definitions read by ApplicationSet
└── <app>/          # Kustomization + values per app

domain/             # Workloads (zcash-stack)
├── defs/           # App definitions read by ApplicationSet
└── <app>/          # Kustomization + values per app

clusters/
├── local/
│   ├── appset.yaml # Single entry point
│   └── values/     # Environment overrides
└── production/
    ├── appset.yaml
    └── values/
```

#### Unified ApplicationSet pattern
- Single `appset.yaml` per cluster
- Multiple generators: reads `platform/defs/*.yaml` + `domain/defs/*.yaml`
- Two app types handled via template conditionals:
  - `type: kustomize` (default) - path-based, for apps defined in devops repo
  - `type: helm-git` - multi-source, for external charts in git repos
- App-specific fields: `syncOptions`, `ignoreDifferences` passed through

#### Branch strategy
- `dev` branch → local cluster
- `main` branch → production cluster
- Same directory structure on both branches
- Promotion = PR from dev to main

#### Helm charts wrapped in Kustomize
- External Helm charts (cert-manager, topolvm, argo-workflows) wrapped via `kustomization.yaml` with `helmCharts:`
- Allows uniform path-based sourcing for all platform apps
- Exception: zcash-stack chart is in git repo (not helm repo), uses `helm-git` type with multi-source

### Files created/modified
- `platform/defs/*.yaml` - App definitions
- `platform/*/kustomization.yaml` - Helm wrappers for external charts
- `domain/defs/zcash-testnet.yaml` - Domain app definition
- `clusters/local/appset.yaml` - Unified ApplicationSet
- `clusters/production/appset.yaml` - Production variant

### Migration notes
- Old Applications created manually need deletion before ApplicationSet takeover
- ApplicationSet expects to "own" Applications it creates
- Clean migration: delete old Apps, apply new appset.yaml

### Issues encountered

#### Git file generator field collision
- **Symptom:** Application source path showed `map[basename:defs ...]` instead of actual path
- **Cause:** Git file generator creates automatic `.path` metadata field (directory containing file)
- **Collision:** Our YAML files had custom `path` field for app source path
- **Fix:** Rename to `sourcePath` in both defs/*.yaml and ApplicationSet template

#### TopoLVM controller anti-affinity on single-node
- **Symptom:** Controller pod stuck in Pending, "didn't match pod anti-affinity rules"
- **Cause:** Chart defaults to 2 replicas with anti-affinity
- **Fix:** Set `controller.replicaCount: 1` in values.yaml
