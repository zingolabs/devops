# deploy-ephemeral: state-mode path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `state-mode` path to the `deploy-ephemeral` WorkflowTemplate that spins up a **zaino-only** ephemeral which read-only-mounts the shared `golden-zebra-state` cache (hostPath on tekau) and RPC-falls-back to a healthy zebra for the non-state surface — no per-instance zebra, no snapshot cloning.

**Architecture:** Purely additive edits to one Argo WorkflowTemplate. New workflow params gate the behavior; the existing `helm upgrade --install` accumulates state-mode `--set` flags into `$OVERRIDES` via an inline `if [ "$STATE_MODE" = "true" ]` block (same pattern as `use-zaino-cache`/`tailscale`). All chart keys used (`zebra.enabled`, `zaino.zebraCache.*`, `zaino.config.backend`, `zaino.config.zebraDbPath`, `zaino.nodeSelector`, `zaino.rpcService`, `zaino.rpcPort`) exist in zcash-stack chart **0.0.24** (Plans 1 + in-cluster-peering).

**Tech Stack:** Argo Workflows (WorkflowTemplate), helm (shell-driven `--set`), the zcash-stack umbrella chart.

**Spec:** `docs/superpowers/specs/2026-08-18-state-mode-zaino-shared-cache-design.md` §6. Plan 3 of 3.

## Design decisions (baked in)
- **Cache source:** `golden-zebra-state`'s hostPath `/srv/zebra-state-cache-mainnet` (RO). Zaino pinned to `tekau` (nodeSelector) since the hostPath lives there.
- **RPC fallback target:** `golden-mainnet`'s zebra (`zebra.golden-mainnet.svc:8232`) — canonical healthy node with the richest mempool. Overridable via a param (e.g. to `zebra.golden-zebra-state.svc` for self-consistency).
- **Ref-agnostic:** `state-backend` (default `state`) sets zaino's `backend`; the deployed zaino ref must wire the read-only-open path. State mode is orthogonal to `ref`/`zaino-tag`.

## File Structure
- Modify: `platform/argo-workflows/workflows/deploy-ephemeral.yaml` — params, clone-step gating, helm-install override block, report step.
- Modify: `.claude/deploy-ephemeral-reference.md` — document the state-mode params + a recipe (repo maintenance rule).
- Modify: `.claude/commands/deploy.md` — mention state-mode.

> Line numbers below are anchors from the current file; the implementer should match on the surrounding text (they may drift).

---

## Task 1: Add state-mode parameters

**File:** `platform/argo-workflows/workflows/deploy-ephemeral.yaml` (params block ~lines 31-80)

- [ ] **Step 1: Add the params after `use-zaino-cache`**

Find:
```yaml
      - name: use-zaino-cache
        value: "false"
      - name: metrics
        value: "true"
```
Insert the five state-mode params between them:
```yaml
      - name: use-zaino-cache
        value: "false"
      # State mode: zaino-only, reads the shared golden-zebra-state cache (RO) +
      # RPC-fallback to a healthy zebra. Requires a zaino ref that opens the cache read-only.
      - name: state-mode
        value: "false"
      - name: state-backend
        value: "state"
      - name: state-cache-hostpath
        value: "/srv/zebra-state-cache-mainnet"
      - name: state-rpc-service
        value: "zebra.golden-mainnet.svc"
      - name: state-rpc-port
        value: "8232"
      - name: metrics
        value: "true"
```

- [ ] **Step 2: Validate YAML still parses**

Run:
```bash
cd /home/chona/zingo/zingolabs/devops
python3 -c "import yaml; list(yaml.safe_load_all(open('platform/argo-workflows/workflows/deploy-ephemeral.yaml'))); print('yaml OK')"
kubectl kustomize platform/argo-workflows/workflows/ >/dev/null 2>&1 && echo "kustomize OK"
```
Expected: `yaml OK` and `kustomize OK`.

- [ ] **Step 3: Commit**

```bash
git add platform/argo-workflows/workflows/deploy-ephemeral.yaml
git commit -m "deploy-ephemeral: add state-mode parameters"
```

---

## Task 2: Skip zebra snapshot cloning in state mode

**File:** `deploy-ephemeral.yaml` (clone steps ~lines 110-130)

- [ ] **Step 1: Gate `clone-zebra-snapshot`**

Find (it currently has NO `when:`):
```yaml
          - name: clone-zebra-snapshot
            template: clone-snapshot
            arguments:
```
Add a `when:` so it skips in state mode:
```yaml
          - name: clone-zebra-snapshot
            template: clone-snapshot
            when: "'{{workflow.parameters.state-mode}}' != 'true'"
            arguments:
```

- [ ] **Step 2: Also guard `clone-zaino-snapshot` for state mode**

Find:
```yaml
          - name: clone-zaino-snapshot
            template: clone-snapshot
            when: "'{{workflow.parameters.use-zaino-cache}}' == 'true'"
```
Change the condition to also require non-state-mode:
```yaml
          - name: clone-zaino-snapshot
            template: clone-snapshot
            when: "'{{workflow.parameters.use-zaino-cache}}' == 'true' && '{{workflow.parameters.state-mode}}' != 'true'"
```

- [ ] **Step 3: Validate + commit**

```bash
cd /home/chona/zingo/zingolabs/devops
python3 -c "import yaml; list(yaml.safe_load_all(open('platform/argo-workflows/workflows/deploy-ephemeral.yaml'))); print('yaml OK')"
git add platform/argo-workflows/workflows/deploy-ephemeral.yaml
git commit -m "deploy-ephemeral: skip snapshot cloning in state mode"
```

---

## Task 3: Inject state-mode helm overrides

**File:** `deploy-ephemeral.yaml` (helm-install step ~lines 297-312)

- [ ] **Step 1: Read the `state-mode` param into a shell var**

Find the var-read block:
```bash
            USE_ZAINO_CACHE="{{workflow.parameters.use-zaino-cache}}"
            BUILT_IMAGE="{{inputs.parameters.image}}"
```
Add `STATE_MODE` after it:
```bash
            USE_ZAINO_CACHE="{{workflow.parameters.use-zaino-cache}}"
            BUILT_IMAGE="{{inputs.parameters.image}}"
            STATE_MODE="{{workflow.parameters.state-mode}}"
```

- [ ] **Step 2: Guard the unconditional zebra dataSource flag**

Find:
```bash
            OVERRIDES=""
            OVERRIDES="$OVERRIDES --set zebra.volumes.data.dataSource.name=zebra-snapshot"
```
Only set it when NOT in state mode (state mode has no zebra):
```bash
            OVERRIDES=""
            if [ "$STATE_MODE" != "true" ]; then
              OVERRIDES="$OVERRIDES --set zebra.volumes.data.dataSource.name=zebra-snapshot"
            fi
```

- [ ] **Step 3: Add the state-mode override block**

Find the `use-zaino-cache` if/else:
```bash
            if [ "$USE_ZAINO_CACHE" = "true" ]; then
              OVERRIDES="$OVERRIDES --set zaino.volumes.data.dataSource.name=zaino-snapshot"
            else
              OVERRIDES="$OVERRIDES --set-json zaino.volumes.data.dataSource=null"
            fi
```
Immediately AFTER that block (still before the image-resolution block), add:
```bash

            # State mode: zaino-only; RO-mount the shared golden-zebra cache + RPC-fallback.
            if [ "$STATE_MODE" = "true" ]; then
              OVERRIDES="$OVERRIDES --set zebra.enabled=false"
              OVERRIDES="$OVERRIDES --set zaino.zebraCache.enabled=true"
              OVERRIDES="$OVERRIDES --set-string zaino.zebraCache.hostPath={{workflow.parameters.state-cache-hostpath}}"
              OVERRIDES="$OVERRIDES --set-string zaino.config.backend={{workflow.parameters.state-backend}}"
              OVERRIDES="$OVERRIDES --set-string zaino.config.zebraDbPath=/var/cache/zebrad-cache"
              OVERRIDES="$OVERRIDES --set-string zaino.nodeSelector.kubernetes\.io/hostname=tekau"
              OVERRIDES="$OVERRIDES --set-string zaino.rpcService={{workflow.parameters.state-rpc-service}}"
              OVERRIDES="$OVERRIDES --set-string zaino.rpcPort={{workflow.parameters.state-rpc-port}}"
            fi
```
(`zaino.zebraCache.mountPath` stays at the chart default `/var/cache/zebrad-cache`, matching `zebraDbPath`.)

- [ ] **Step 4: Simulate the resulting helm render**

Prove the state-mode `--set` flags produce the intended manifest against the real chart:
```bash
helm template zaino /home/chona/zingo/zingolabs/zcash-stack/charts/zcash-stack \
  -f /home/chona/zingo/zingolabs/devops/platform/argo-workflows/workflows/ephemeral-values.yaml \
  --set zebra.enabled=false \
  --set zaino.enabled=true \
  --set zaino.zebraCache.enabled=true \
  --set-string zaino.zebraCache.hostPath=/srv/zebra-state-cache-mainnet \
  --set-string zaino.config.backend=state \
  --set-string zaino.config.zebraDbPath=/var/cache/zebrad-cache \
  --set-string 'zaino.nodeSelector.kubernetes\.io/hostname=tekau' \
  --set-string zaino.rpcService=zebra.golden-mainnet.svc \
  --set-string zaino.rpcPort=8232 2>&1 | tee /tmp/sm3.yaml >/dev/null
echo "zebra STS (want 0):"; grep -c "name: zebra$" /tmp/sm3.yaml
echo "checks:"; grep -E "name: zebra-cache|readOnly: true|backend = 'state'|zebra_db_path = '/var/cache/zebrad-cache'|hostname: tekau" /tmp/sm3.yaml
rm -f /tmp/sm3.yaml
```
Expected: `zebra STS (want 0): 0`; and all of `name: zebra-cache`, `readOnly: true`, `backend = 'state'`, `zebra_db_path = '/var/cache/zebrad-cache'`, `hostname: tekau` present.
(Note: `ephemeral-values.yaml` here refers to the workflow-dir file used as the helm base; if its path/keys differ, use `platform/argo-workflows/workflows/ephemeral-values.yaml` and confirm it carries `zaino.rpcService`. The simulation only needs to prove the state-mode flags render.)

- [ ] **Step 5: Validate YAML + commit**

```bash
cd /home/chona/zingo/zingolabs/devops
python3 -c "import yaml; list(yaml.safe_load_all(open('platform/argo-workflows/workflows/deploy-ephemeral.yaml'))); print('yaml OK')"
git add platform/argo-workflows/workflows/deploy-ephemeral.yaml
git commit -m "deploy-ephemeral: inject state-mode helm overrides (RO cache mount + RPC fallback)"
```

---

## Task 4: State-mode output in the report step

**File:** `deploy-ephemeral.yaml` (report-endpoint ~lines 445-448)

- [ ] **Step 1: Guard the Zebra RPC line**

Find:
```bash
            echo "Zaino gRPC: zaino.{{workflow.parameters.namespace}}.svc:8137"
            echo "Zebra RPC:  zebra.{{workflow.parameters.namespace}}.svc:8232"
```
Replace the Zebra RPC line with a state-mode-aware branch:
```bash
            echo "Zaino gRPC: zaino.{{workflow.parameters.namespace}}.svc:8137"
            if [ "{{workflow.parameters.state-mode}}" = "true" ]; then
              echo "Mode:       STATE (reads {{workflow.parameters.state-cache-hostpath}} RO on tekau)"
              echo "Zebra RPC:  {{workflow.parameters.state-rpc-service}}:{{workflow.parameters.state-rpc-port}} (external fallback)"
            else
              echo "Zebra RPC:  zebra.{{workflow.parameters.namespace}}.svc:8232"
            fi
```

- [ ] **Step 2: Validate + commit**

```bash
cd /home/chona/zingo/zingolabs/devops
python3 -c "import yaml; list(yaml.safe_load_all(open('platform/argo-workflows/workflows/deploy-ephemeral.yaml'))); print('yaml OK')"
git add platform/argo-workflows/workflows/deploy-ephemeral.yaml
git commit -m "deploy-ephemeral: report state-mode endpoints"
```

---

## Task 5: Docs (repo maintenance rule)

**Files:** `.claude/deploy-ephemeral-reference.md`, `.claude/commands/deploy.md`

- [ ] **Step 1: Add the state-mode params to the reference table**

In `.claude/deploy-ephemeral-reference.md`, in the "All parameters" table, add rows:
```markdown
| `state-mode` | `false` | Zaino-only: RO-mount the shared golden-zebra-state cache + RPC-fallback; no per-instance zebra |
| `state-backend` | `state` | Zaino `backend` selector for state mode (ref must wire read-only-open) |
| `state-cache-hostpath` | `/srv/zebra-state-cache-mainnet` | hostPath (tekau) of the shared cache to RO-mount |
| `state-rpc-service` | `zebra.golden-mainnet.svc` | Zebra RPC endpoint for mempool/tip/tx-submit fallback |
| `state-rpc-port` | `8232` | Port for the RPC fallback |
```
And add a recipe under "Common recipes":
```markdown
# State-mode: zaino-only against the shared live golden-zebra cache
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=state-<shorthash> \
  -p ref=<full-40-char-hash-of-a-readstate-capable-zaino> \
  -p state-mode=true
```

- [ ] **Step 2: Mention state-mode in the deploy command doc**

In `.claude/commands/deploy.md`, add a short note that `-p state-mode=true` deploys a zaino-only instance reading the shared `golden-zebra-state` cache (requires a zaino ref that opens the cache read-only), RPC-falling-back to `golden-mainnet`.

- [ ] **Step 3: Commit + devlog reminder**

```bash
cd /home/chona/zingo/zingolabs/devops
git add .claude/deploy-ephemeral-reference.md .claude/commands/deploy.md
git commit -m "docs: document deploy-ephemeral state-mode path"
```
Then remind the user to append the devlog with the Plan 3 outcome.

---

## Validation (after merge to main)

- [ ] **Workflow applies:** merge to `main`, confirm ArgoCD syncs `snapshot-workflows` and `argo template get deploy-ephemeral` shows the new params.
- [ ] **End-to-end (needs a readstate-capable zaino ref):**
```bash
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=state-test-<shorthash> -p ref=<readstate-zaino-hash> -p state-mode=true --watch
```
  Then verify: the namespace has a **zaino pod but no zebra**; zaino is on `tekau`; `zaino.toml` has `backend='state'` + `zebra_db_path=/var/cache/zebrad-cache`; the zebra-cache RO mount is present; and zaino serves gRPC on :8137 reading the shared cache. If the ref's fallback needs the indexer gRPC (:8230) rather than JSON-RPC, resolve spec §7.2 (expose 8230 on the RPC target).

## Self-Review
- **Spec §6 coverage:** params (Task 1); skip clones (Task 2); helm overrides `zebra.enabled=false` + zebraCache RO + backend + zebraDbPath + nodeSelector + rpcService/rpcPort (Task 3); report (Task 4); docs (Task 5). All present.
- **Pattern fidelity:** state-mode uses the same inline-`if`/`$OVERRIDES` mechanism as `use-zaino-cache`/`tailscale`; `--set-string` with escaped-dot nodeSelector mirrors the tailscale-annotation line.
- **No placeholders:** every edit shows verbatim before/after; verification commands are concrete.
- **Assumption:** chart 0.0.24 keys exist (verified in Plans 1 + peering). The only unproven external is a zaino ref that wires `ZebraReadStateAdapter::open` — flagged as the end-to-end gate.
