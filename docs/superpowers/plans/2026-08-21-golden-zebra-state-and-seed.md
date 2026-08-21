# golden-zebra-state (mainnet) + seed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a dedicated mainnet `golden-zebra-state` zebra whose RocksDB cache lives on a hostPath on tekau's root disk, seeded once from the live `golden-mainnet` snapshot, so state-mode zainos (Plan 3) can read it live.

**Architecture:** Two GitOps manifests (an ArgoCD def + its values) create a *zebra-only* zcash-stack release with the Plan-1 chart hooks (`zebra.volumes.data.hostPath`, `zebra.nodeSelector`). A one-time Argo `WorkflowTemplate` populates the hostPath from a fresh crash-consistent VolumeSnapshot of `zebra-data-zebra-0` (RocksDB recovers from crash-consistent snapshots — the existing ephemeral flow relies on the same property). **Ordering is load-bearing: seed the hostPath BEFORE the app goes live, or zebra starts on an empty dir and syncs from genesis.**

**Tech Stack:** ArgoCD ApplicationSet (git generator), Helm (zcash-stack chart on `main`, 0.0.23), Argo Workflows, topolvm CSI snapshots.

**Spec:** `docs/superpowers/specs/2026-08-18-state-mode-zaino-shared-cache-design.md` (§4.1, §4.2). This is Plan 2 of 3.

---

## Preflight

- [ ] **P1: Branch in the devops repo**

```bash
cd /home/chona/zingo/zingolabs/devops
git checkout -b feat/golden-zebra-state
git status
```
Expected: on `feat/golden-zebra-state`. (Do not commit to `dev`/`main` directly; merges to `main` are what ArgoCD syncs — sequenced deliberately in Task 4.)

> **Repo conventions:** commit messages imperative, **no `Co-Authored-By`/"Generated with" trailers**. Use kubeconfig context `zingo-infra` for any `kubectl`/`argo`. Prefer GitOps for managed resources; the seed is a one-off maintenance `argo submit` (same pattern as `snapshot-golden`/`deploy-ephemeral`).

---

## File Structure

- Create: `clusters/production/values/golden-zebra-state.yaml` — zebra-only zcash-stack values, hostPath cache, tekau affinity.
- Create: `domain/defs/golden-zebra-state.yaml` — ArgoCD app def (auto-discovered by the `domain` ApplicationSet).
- Create: `platform/argo-workflows/workflows/seed-zebra-state-cache.yaml` — one-time seed `WorkflowTemplate`.
- Modify: `platform/argo-workflows/workflows/kustomization.yaml` — register the new workflow file.

**Naming constraint (verified):** the `domain` ApplicationSet hardcodes the values path as `clusters/production/values/<def-name>.yaml`, so the def `name:` (`golden-zebra-state`) and the values filename MUST match.

---

## Task 1: `golden-zebra-state` values + ArgoCD def

**Files:**
- Create: `clusters/production/values/golden-zebra-state.yaml`
- Create: `domain/defs/golden-zebra-state.yaml`

- [ ] **Step 1: Write the values file**

Create `clusters/production/values/golden-zebra-state.yaml`:
```yaml
# Mainnet zebra whose state cache lives on a hostPath (tekau root disk),
# read live by state-mode zainos. Zebra only — no zaino/lightwalletd/zcashd.
ingress:
  enabled: false

zebra:
  enabled: true
  name: zebra
  testnet: false
  replicas: 1
  image:
    tag: "6.3.0"
    hash: ""
  # Plan-1 chart hook: back the state cache with a hostPath dir (omits the PVC).
  volumes:
    data:
      hostPath: /srv/zebra-state-cache-mainnet
  # Plan-1 chart hook: pin to the storage node.
  nodeSelector:
    kubernetes.io/hostname: tekau
  requests:
    cpu: 2
    memory: 4Gi
  limits:
    memory: 24Gi

zaino:
  enabled: false
lightwalletd:
  enabled: false
zcashd:
  enabled: false
```

- [ ] **Step 2: Write the ArgoCD def**

Create `domain/defs/golden-zebra-state.yaml` (mirrors `golden-mainnet.yaml`):
```yaml
name: golden-zebra-state
namespace: golden-zebra-state
type: helm-git
chartRepo: https://github.com/zingolabs/zcash-stack
chartPath: charts/zcash-stack
chartRevision: main
valuesFile: clusters/production/values/golden-zebra-state.yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/replicas
```

- [ ] **Step 3: Render with the local chart and assert (zebra-only, hostPath, tekau, no PVC)**

Run (uses the local zcash-stack checkout, already on `main` with the 0.0.23 hooks):
```bash
helm template golden-zebra-state /home/chona/zingo/zingolabs/zcash-stack/charts/zcash-stack \
  -f /home/chona/zingo/zingolabs/devops/clusters/production/values/golden-zebra-state.yaml \
  > /tmp/gzs-render.yaml 2>&1
echo "StatefulSets:"; grep -c "kind: StatefulSet" /tmp/gzs-render.yaml
echo "checks:"; grep -E "image: zfnd/zebra:6.3.0|path: /srv/zebra-state-cache-mainnet|kubernetes.io/hostname: tekau|volumeClaimTemplates:|containerPort: 8232" /tmp/gzs-render.yaml
echo "no zaino/lwd:"; grep -cE "name: zaino$|name: lightwalletd$" /tmp/gzs-render.yaml
```
Expected:
- `StatefulSets:` → `1` (zebra only).
- checks → `image: zfnd/zebra:6.3.0`, `path: /srv/zebra-state-cache-mainnet`, `kubernetes.io/hostname: tekau`, `containerPort: 8232` all present; **`volumeClaimTemplates:` ABSENT** (hostPath omits it).
- `no zaino/lwd:` → `0`.

- [ ] **Step 4: Clean up and commit**

```bash
rm -f /tmp/gzs-render.yaml
cd /home/chona/zingo/zingolabs/devops
git add clusters/production/values/golden-zebra-state.yaml domain/defs/golden-zebra-state.yaml
git commit -m "Add golden-zebra-state (mainnet, hostPath cache) app def + values"
```

---

## Task 2: seed `WorkflowTemplate` + register it

**Files:**
- Create: `platform/argo-workflows/workflows/seed-zebra-state-cache.yaml`
- Modify: `platform/argo-workflows/workflows/kustomization.yaml`

- [ ] **Step 1: Write the seed WorkflowTemplate**

Create `platform/argo-workflows/workflows/seed-zebra-state-cache.yaml`. It runs in `argo` under SA `snapshot-workflow` (existing RBAC covers VolumeSnapshots + PVCs + Jobs), and does everything in the `golden-mainnet` namespace: snapshot `zebra-data-zebra-0`, provision a temp PVC from it, run a tekau-pinned Job that copies the cache into the hostPath, then clean up.
```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: seed-zebra-state-cache
  namespace: argo
spec:
  serviceAccountName: snapshot-workflow
  entrypoint: seed
  arguments:
    parameters:
      - name: source-namespace
        value: golden-mainnet
      - name: source-pvc
        value: zebra-data-zebra-0
      - name: node
        value: tekau
      - name: host-path
        value: /srv/zebra-state-cache-mainnet
      - name: snapshot-class
        value: topolvm-snapshot
      - name: storage-class
        value: topolvm-thin
      - name: seed-pvc-size
        value: 350Gi
  templates:
    - name: seed
      steps:
        - - name: snapshot
            template: make-snapshot
        - - name: seed-pvc
            template: make-seed-pvc
        - - name: copy
            template: copy-job
        - - name: cleanup
            template: cleanup

    - name: make-snapshot
      resource:
        action: create
        setOwnerReference: false
        successCondition: status.readyToUse == true
        manifest: |
          apiVersion: snapshot.storage.k8s.io/v1
          kind: VolumeSnapshot
          metadata:
            name: zebra-state-seed-snap
            namespace: '{{workflow.parameters.source-namespace}}'
          spec:
            volumeSnapshotClassName: '{{workflow.parameters.snapshot-class}}'
            source:
              persistentVolumeClaimName: '{{workflow.parameters.source-pvc}}'

    - name: make-seed-pvc
      # NOTE: no wait-for-Bound — topolvm-thin is WaitForFirstConsumer, so the
      # PVC stays Pending until the copy Job (next step) schedules and binds it.
      resource:
        action: create
        setOwnerReference: false
        manifest: |
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: zebra-state-seed-src
            namespace: '{{workflow.parameters.source-namespace}}'
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: '{{workflow.parameters.storage-class}}'
            resources:
              requests:
                storage: '{{workflow.parameters.seed-pvc-size}}'
            dataSource:
              apiGroup: snapshot.storage.k8s.io
              kind: VolumeSnapshot
              name: zebra-state-seed-snap

    - name: copy-job
      resource:
        action: create
        setOwnerReference: false
        successCondition: status.succeeded == 1
        failureCondition: status.failed > 0
        manifest: |
          apiVersion: batch/v1
          kind: Job
          metadata:
            name: zebra-state-seed-copy
            namespace: '{{workflow.parameters.source-namespace}}'
          spec:
            backoffLimit: 0
            activeDeadlineSeconds: 86400
            ttlSecondsAfterFinished: 3600
            template:
              spec:
                restartPolicy: Never
                nodeSelector:
                  kubernetes.io/hostname: '{{workflow.parameters.node}}'
                containers:
                  - name: copy
                    image: busybox:latest
                    command: ["/bin/sh", "-c"]
                    args:
                      - |
                        set -e
                        echo "seeding {{workflow.parameters.host-path}} from snapshot..."
                        cp -a /src/. /dst/
                        chown 2001:2001 /dst
                        echo "done; contents:"; ls -la /dst
                    volumeMounts:
                      - name: src
                        mountPath: /src
                        readOnly: true
                      - name: dst
                        mountPath: /dst
                volumes:
                  - name: src
                    persistentVolumeClaim:
                      claimName: zebra-state-seed-src
                  - name: dst
                    hostPath:
                      path: '{{workflow.parameters.host-path}}'
                      type: DirectoryOrCreate

    - name: cleanup
      resource:
        action: delete
        manifest: |
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: zebra-state-seed-src
            namespace: '{{workflow.parameters.source-namespace}}'
```
> Note: the temp VolumeSnapshot `zebra-state-seed-snap` is intentionally left (topolvm snapshot class is `deletionPolicy: Retain`); delete it by hand after a successful seed, or re-running the template will fail on the existing name — see the runbook.

- [ ] **Step 2: Register it in the kustomization**

In `platform/argo-workflows/workflows/kustomization.yaml`, add `seed-zebra-state-cache.yaml` to the `resources:` list (alphabetical-ish, next to the other workflow files). After editing, confirm:
```bash
grep seed-zebra-state-cache /home/chona/zingo/zingolabs/devops/platform/argo-workflows/workflows/kustomization.yaml
```
Expected: prints the line.

- [ ] **Step 3: Validate the manifests build**

Run:
```bash
cd /home/chona/zingo/zingolabs/devops
kubectl kustomize platform/argo-workflows/workflows/ > /tmp/wf-build.yaml 2>&1 && echo "kustomize OK"
grep -c "name: seed-zebra-state-cache" /tmp/wf-build.yaml
kubectl apply --dry-run=client -f platform/argo-workflows/workflows/seed-zebra-state-cache.yaml --context zingo-infra 2>&1 | tail -2
rm -f /tmp/wf-build.yaml
```
Expected: `kustomize OK`; the grep prints `1`; the dry-run reports the WorkflowTemplate `created (dry run)` with no schema errors.

- [ ] **Step 4: Commit**

```bash
cd /home/chona/zingo/zingolabs/devops
git add platform/argo-workflows/workflows/seed-zebra-state-cache.yaml platform/argo-workflows/workflows/kustomization.yaml
git commit -m "Add seed-zebra-state-cache workflow to populate the mainnet state hostPath"
```

---

## Task 3: create the hostPath directory on tekau

**File:** none (host step).

- [ ] **Step 1: Create the cache dir**

The auto-mode classifier may block remote host mutations; if so, run it yourself. Command:
```bash
ssh root@tekau 'mkdir -p /srv/zebra-state-cache-mainnet && chown 2001:2001 /srv/zebra-state-cache-mainnet && ls -ld /srv/zebra-state-cache-mainnet'
```
Expected: prints the dir, owner `2001 2001`. (An empty dir is fine — the seed Job fills it; zebra's `set-permissions` init also chowns on first boot.)

---

## Task 4: Deploy — ordered runbook (seed BEFORE app)

> This is the load-bearing sequence. Each merge to `main` is what ArgoCD acts on.

- [ ] **Step 1: Land the seed workflow on `main` (dormant until submitted)**

Merge the Task 2 commit to `main` (open a PR or fast-forward per your flow) and let ArgoCD sync the `snapshot-workflows` app. Confirm the template is registered:
```bash
argo template list -n argo --context zingo-infra | grep seed-zebra-state-cache
```
Expected: the template appears. (The `golden-zebra-state` def/values from Task 1 are NOT on `main` yet — hold them for Step 4.)

- [ ] **Step 2: Run the seed**

```bash
argo submit --from workflowtemplate/seed-zebra-state-cache -n argo --context zingo-infra --watch
```
Expected: all four steps (`snapshot` → `seed-pvc` → `copy` → `cleanup`) succeed. The copy step moves ~260Gi and will take a while; `activeDeadlineSeconds` allows up to 24h.

- [ ] **Step 3: Verify the hostPath is populated and valid**

```bash
ssh root@tekau 'du -sh /srv/zebra-state-cache-mainnet; ls /srv/zebra-state-cache-mainnet/state/ 2>/dev/null; stat -c "%U:%G" /srv/zebra-state-cache-mainnet/state 2>/dev/null'
```
Expected: ~260Gi; a `state/v28/mainnet` (or current vN) tree present; owned `2001:2001`. Then delete the retained temp snapshot so a future re-seed is clean:
```bash
kubectl delete volumesnapshot zebra-state-seed-snap -n golden-mainnet --context zingo-infra
```

- [ ] **Step 4: Land `golden-zebra-state` on `main` → ArgoCD deploys**

Merge the Task 1 commit to `main`. The `domain` ApplicationSet creates the app; ArgoCD deploys zebra onto the seeded hostPath.
```bash
kubectl -n golden-zebra-state get pod,svc --context zingo-infra
```
Expected: a `zebra-0` pod on `tekau`, and a zebra Service.

- [ ] **Step 5: Verify zebra opened the SEEDED cache (not genesis-syncing)**

```bash
kubectl -n golden-zebra-state logs zebra-0 --context zingo-infra | grep -iE "initial tip|finalized|height|opened" | head
```
Expected: startup shows a high tip height near mainnet tip within minutes (it opened the seed and is catching up the last blocks) — **not** height 0/genesis. Then confirm RPC:
```bash
kubectl -n golden-zebra-state exec zebra-0 --context zingo-infra -- \
  wget -qO- --post-data='{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}' \
  --header='Content-Type: application/json' http://localhost:8232/ | head -c 400
```
Expected: JSON with `"blocks"` near mainnet tip.

- [ ] **Step 6: Record the RPC service DNS for Plan 3**

```bash
kubectl -n golden-zebra-state get svc --context zingo-infra -o custom-columns=NAME:.metadata.name,PORTS:.spec.ports[*].port
```
Expected: note the zebra service name; the state-mode zaino (Plan 3) will point `rpcService` at `<svc>.golden-zebra-state.svc` and `rpcPort=8232`. (The chart's headless service is `zebra-service`; confirm whether a plain `zebra` ClusterIP also exists, as in golden-mainnet.)

---

## Self-Review

- **Spec coverage:** §4.1 golden-zebra-state (mainnet, zebra 6.3.0, hostPath `/srv/zebra-state-cache-mainnet`, nodeAffinity tekau, exposes 8232, zebra-only) → Task 1. §4.2 one-time seed from a golden-mainnet snapshot → Task 2 + Task 4. §7.1 hostPath dir → Task 3. Registration mechanics (appset auto-discovery; workflow needs kustomization edit) → reflected in Tasks 1–2.
- **Ordering:** the runbook explicitly seeds (Task 4 Steps 1–3) before the app goes live (Step 4), preventing a genesis resync.
- **No placeholders:** all manifests are complete; every step has an exact command + expected output.
- **Consumption reality:** ArgoCD reads from git `main` via helm-git, so both the def/values and the workflow only take effect once merged to `main` — the runbook merges them in the correct order.
- **Assumptions to watch:** (1) the chart's zebra service name for cross-namespace RPC (confirmed in Step 6, feeds Plan 3); (2) `cp -a` preserves 2001 ownership from the snapshot (it does — block-level snapshot keeps fs metadata); (3) zebra 6.3.0 opens a crash-consistent snapshot cleanly (same property the existing ephemeral clone-restore already relies on).
```
