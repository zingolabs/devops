# State-mode zaino: zcash-stack chart changes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the gated, defaulted chart hooks the `zcash-stack` Helm chart needs so a zaino can (a) read an external Zebra state-db cache read-only from a hostPath, (b) be told which `backend`/`zebra_db_path`/RPC-port to use, and (c) be pinned to a node — plus let a Zebra put its cache on a hostPath. All additive, all defaulting to current behavior.

**Architecture:** Pure Helm template + values edits in `zingolabs/zcash-stack`. No new templates — we extend `zebra-statefulset.yaml`, `zaino-statefulset.yaml`, `zaino-configmap.yaml`, and `values.yaml`. Every change is gated behind a new values key whose default reproduces today's rendered output; verification is done with `helm template`/`helm lint` (no cluster needed). This is Plan 1 of 3 for Phase 1 (testnet); Plans 2 (golden-zebra-state + seed) and 3 (deploy-ephemeral state-mode path) consume the released chart.

**Tech Stack:** Helm 3, Go templates, YAML. Chart lives at `/home/chona/zingo/zingolabs/zcash-stack/charts/zcash-stack`.

**Spec:** `docs/superpowers/specs/2026-08-18-state-mode-zaino-shared-cache-design.md` (§5 is the chart-changes source of truth).

---

## Preflight (do once before Task 1)

- [ ] **P1: Confirm `helm` is available**

Run: `helm version --short`
Expected: prints a v3.x version. If missing, install helm before continuing (no cluster is required — we only use `helm template`/`lint`).

- [ ] **P2: Work on a branch in the zcash-stack repo**

The chart is a **separate repo** (`zingolabs/zcash-stack`) whose `main` branch auto-publishes a chart release on merge. Do NOT commit to `main`. All work here is on a feature branch; releasing (merge to main) is a deliberate step handed to Plan 2.

```bash
cd /home/chona/zingo/zingolabs/zcash-stack
git checkout main && git pull
git checkout -b feat/state-mode-cache-hooks
git status
```
Expected: on branch `feat/state-mode-cache-hooks`, clean tree.

> **Convention (inferred — repo has no CLAUDE.md):** one top-level values key per component; new behavior gated behind a values key with a behavior-preserving default; optional blocks via `{{- with … }}`. Commits are small, single-purpose, imperative (e.g. "Add zaino zebraCache read-only mount support"). **No `Co-Authored-By` / "Generated with" trailers.** All commands below assume CWD `= /home/chona/zingo/zingolabs/zcash-stack/charts/zcash-stack`.

---

## File Structure

- Modify: `charts/zcash-stack/values.yaml` — add `zaino.config.backend`, `zaino.config.zebraDbPath`, `zaino.rpcPort`, `zaino.zebraCache.*`, `zebra.volumes.data.hostPath` (doc), `{zebra,zaino}.{nodeSelector,affinity,tolerations}`.
- Modify: `charts/zcash-stack/templates/zaino-configmap.yaml` — make `backend` and `zebra_db_path` value-driven.
- Modify: `charts/zcash-stack/templates/zaino-statefulset.yaml` — value-driven init-rpc port; optional RO `zebra-cache` hostPath mount; scheduling hooks.
- Modify: `charts/zcash-stack/templates/zebra-statefulset.yaml` — optional hostPath cache source; scheduling hooks.
- Modify: `charts/zcash-stack/Chart.yaml` — version bump.

**Out of scope for this plan (follow-ups):** chart `README.md` values docs; zebra indexer gRPC :8230 (spec §7.2, deferred until we know the target zaino ref needs it); `golden-zebra-state` deployment/seed (Plan 2); `deploy-ephemeral` (Plan 3).

**Notes for consumers (Plans 2/3):** a state-mode testnet zaino sets `zebra.enabled=false`, `zebra.testnet=true` (the zaino configmap reads `.Values.zebra.testnet` for network + validator ports even when zebra isn't rendered), `zaino.rpcPort=18232`, `zaino.zebraCache.enabled=true`, `zaino.config.backend=state`, and `zaino.config.zebraDbPath` = `zaino.zebraCache.mountPath`.

---

## Task 1: Value-driven zaino `backend` and `zebra_db_path`

**Files:**
- Modify: `charts/zcash-stack/values.yaml` (`zaino.config`, ~line 198)
- Modify: `charts/zcash-stack/templates/zaino-configmap.yaml` (lines 8-9)

- [ ] **Step 1: Write the failing test (render with an override)**

Run:
```bash
helm template t . --set zaino.enabled=true --set zaino.config.backend=state \
  --set zaino.config.zebraDbPath=/var/cache/zebrad-cache \
  --show-only templates/zaino-configmap.yaml | grep -E "^ +backend =|^ +zebra_db_path ="
```
Expected NOW (FAIL): prints `backend = 'fetch'` and `zebra_db_path = '/home/zaino/.cache/zebra'` — the overrides are ignored because the values are hardcoded.

- [ ] **Step 2: Add the values**

In `values.yaml`, under `zaino.config` change:
```yaml
  config:
    dbSize: 64
    noSync: false
    noDB: false
    noState: false
```
to:
```yaml
  config:
    dbSize: 64
    # Zaino backend selector: 'fetch' (JSON-RPC) or 'state'/'direct' (read Zebra's state db)
    backend: fetch
    # Path to Zebra's cache_dir (state-db root); used by the state/direct backends
    zebraDbPath: /home/zaino/.cache/zebra
    noSync: false
    noDB: false
    noState: false
```

- [ ] **Step 3: Make the configmap value-driven**

In `templates/zaino-configmap.yaml`, change lines 8-9:
```yaml
    backend = 'fetch'
    zebra_db_path = '/home/zaino/.cache/zebra'
```
to:
```yaml
    backend = '{{ .Values.zaino.config.backend }}'
    zebra_db_path = '{{ .Values.zaino.config.zebraDbPath }}'
```

- [ ] **Step 4: Run the test — override now applies**

Run:
```bash
helm template t . --set zaino.enabled=true --set zaino.config.backend=state \
  --set zaino.config.zebraDbPath=/var/cache/zebrad-cache \
  --show-only templates/zaino-configmap.yaml | grep -E "^ +backend =|^ +zebra_db_path ="
```
Expected (PASS): `backend = 'state'` and `zebra_db_path = '/var/cache/zebrad-cache'`.

- [ ] **Step 5: Verify the default is unchanged (regression guard)**

Run:
```bash
helm template t . --set zaino.enabled=true \
  --show-only templates/zaino-configmap.yaml | grep -E "^ +backend =|^ +zebra_db_path ="
```
Expected: `backend = 'fetch'` and `zebra_db_path = '/home/zaino/.cache/zebra'` (behavior preserved).

- [ ] **Step 6: Commit**

```bash
git add charts/zcash-stack/values.yaml charts/zcash-stack/templates/zaino-configmap.yaml
git commit -m "Make zaino backend and zebra_db_path value-driven"
```

---

## Task 2: Value-driven init-rpc readiness port (`zaino.rpcPort`)

Fixes the latent bug: the `init-rpc` wait derives its port from `zebra.enabled`, so a zaino pointed at an *external* testnet zebra waits on `:8232` while testnet zebra listens on `:18232`.

**Files:**
- Modify: `charts/zcash-stack/values.yaml` (`zaino`, near `rpcService`)
- Modify: `charts/zcash-stack/templates/zaino-statefulset.yaml` (line 31)

- [ ] **Step 1: Write the failing test**

Run:
```bash
helm template t . --set zaino.enabled=true --set zaino.rpcPort=18232 \
  --show-only templates/zaino-statefulset.yaml | grep -E "nc -zv"
```
Expected NOW (FAIL): the `nc -zv` line ends in `:8232` (the override is ignored).

- [ ] **Step 2: Add the value**

In `values.yaml`, under `zaino:` immediately after `rpcService: zebra` (line 177), add:
```yaml
  # Override the JSON-RPC port the init-rpc readiness check waits on.
  # Empty = derive from network. Set for external validators (e.g. 18232 testnet).
  rpcPort: ""
```

- [ ] **Step 3: Use it in the init-rpc container**

In `templates/zaino-statefulset.yaml`, replace line 31:
```yaml
        command: ['sh', '-c', "until nc -zv {{ .Values.zaino.rpcService }}:{{ if .Values.zebra.enabled }}{{ if .Values.zebra.testnet }}18232{{ else }}8232{{ end }}{{ else }}{{ if .Values.zcashd.testnet }}18232{{ else }}8232{{ end }}{{ end }}; do echo waiting for rpc; sleep 2; done"]
```
with:
```yaml
        command: ['sh', '-c', "until nc -zv {{ .Values.zaino.rpcService }}:{{ if .Values.zaino.rpcPort }}{{ .Values.zaino.rpcPort }}{{ else }}{{ if .Values.zebra.enabled }}{{ if .Values.zebra.testnet }}18232{{ else }}8232{{ end }}{{ else }}{{ if .Values.zcashd.testnet }}18232{{ else }}8232{{ end }}{{ end }}{{ end }}; do echo waiting for rpc; sleep 2; done"]
```

- [ ] **Step 4: Run the test — override applies**

Run:
```bash
helm template t . --set zaino.enabled=true --set zaino.rpcPort=18232 \
  --show-only templates/zaino-statefulset.yaml | grep -E "nc -zv"
```
Expected (PASS): the `nc -zv` line ends in `:18232`.

- [ ] **Step 5: Verify the default is unchanged**

Run:
```bash
helm template t . --set zaino.enabled=true \
  --show-only templates/zaino-statefulset.yaml | grep -E "nc -zv"
```
Expected: the line ends in `:8232` (default preserved).

- [ ] **Step 6: Commit**

```bash
git add charts/zcash-stack/values.yaml charts/zcash-stack/templates/zaino-statefulset.yaml
git commit -m "Add zaino.rpcPort override for init-rpc readiness against external validators"
```

---

## Task 3: Optional read-only Zebra-cache mount on zaino (`zaino.zebraCache`)

**Files:**
- Modify: `charts/zcash-stack/values.yaml` (`zaino`, after `runAsGroup`)
- Modify: `charts/zcash-stack/templates/zaino-statefulset.yaml` (container `volumeMounts`, pod `volumes`)

- [ ] **Step 1: Write the failing test**

Run:
```bash
helm template t . --set zaino.enabled=true --set zaino.zebraCache.enabled=true \
  --set zaino.zebraCache.hostPath=/srv/zebra-state-cache-testnet \
  --show-only templates/zaino-statefulset.yaml | grep -c "name: zebra-cache"
```
Expected NOW (FAIL): `0` (no such volume/mount exists).

- [ ] **Step 2: Add the values**

In `values.yaml`, under `zaino:` after `runAsGroup: 1000` (line 197) and before `config:`, add:
```yaml
  # Optional: mount an external Zebra state-db cache (read-only) for state-mode zaino.
  zebraCache:
    enabled: false
    hostPath: ""            # host directory holding Zebra's cache_dir (the seeded shared cache)
    mountPath: /var/cache/zebrad-cache
    readOnly: true
```

- [ ] **Step 3: Add the container volumeMount**

In `templates/zaino-statefulset.yaml`, in the `zaino` container's `volumeMounts:` (after the `config` mount, line 67-68), add:
```yaml
        - name: config
          mountPath: /etc/zaino
        {{- if .Values.zaino.zebraCache.enabled }}
        - name: zebra-cache
          mountPath: {{ .Values.zaino.zebraCache.mountPath }}
          readOnly: {{ .Values.zaino.zebraCache.readOnly }}
        {{- end }}
```

- [ ] **Step 4: Add the pod volume**

In the same file, in the pod-level `volumes:` (after the `config` volume, lines 83-85), add:
```yaml
      volumes:
      - name: config
        configMap:
          name: {{ .Values.zaino.name }}-config
      {{- if .Values.zaino.zebraCache.enabled }}
      - name: zebra-cache
        hostPath:
          path: {{ .Values.zaino.zebraCache.hostPath }}
          type: Directory
      {{- end }}
```
(`type: Directory` requires the seeded cache to pre-exist — a missing mount fails loudly rather than silently creating an empty dir.)

- [ ] **Step 5: Run the test — mount + volume render**

Run:
```bash
helm template t . --set zaino.enabled=true --set zaino.zebraCache.enabled=true \
  --set zaino.zebraCache.hostPath=/srv/zebra-state-cache-testnet \
  --show-only templates/zaino-statefulset.yaml | grep -c "name: zebra-cache"
```
Expected (PASS): `2` (one volumeMount + one volume).

Also confirm read-only + path:
```bash
helm template t . --set zaino.enabled=true --set zaino.zebraCache.enabled=true \
  --set zaino.zebraCache.hostPath=/srv/zebra-state-cache-testnet \
  --show-only templates/zaino-statefulset.yaml | grep -E "readOnly: true|path: /srv/zebra-state-cache-testnet|mountPath: /var/cache/zebrad-cache"
```
Expected: all three lines present.

- [ ] **Step 6: Verify default renders no zebra-cache**

Run:
```bash
helm template t . --set zaino.enabled=true \
  --show-only templates/zaino-statefulset.yaml | grep -c "name: zebra-cache"
```
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add charts/zcash-stack/values.yaml charts/zcash-stack/templates/zaino-statefulset.yaml
git commit -m "Add optional read-only zebraCache hostPath mount to zaino"
```

---

## Task 4: Optional hostPath cache source for Zebra

**Files:**
- Modify: `charts/zcash-stack/values.yaml` (`zebra.volumes.data`, doc only)
- Modify: `charts/zcash-stack/templates/zebra-statefulset.yaml` (pod `volumes` + `volumeClaimTemplates`)

- [ ] **Step 1: Write the failing test**

Run:
```bash
helm template t . --set zebra.enabled=true \
  --set zebra.volumes.data.hostPath=/srv/zebra-state-cache-testnet \
  --show-only templates/zebra-statefulset.yaml | grep -E "hostPath:|volumeClaimTemplates:"
```
Expected NOW (FAIL): prints `volumeClaimTemplates:` but **no** `hostPath:` — the cache is still a PVC and the hostPath override is ignored.

- [ ] **Step 2: Document the value**

In `values.yaml`, under `zebra.volumes.data` (lines 20-27), add a hostPath comment after `size: 400Gi`:
```yaml
  volumes:
    data:
      size: 400Gi
      # Optional: back the state cache with a hostPath dir instead of a PVC
      # (single-node shared cache). When set, the volumeClaimTemplate is omitted.
      # hostPath: /srv/zebra-state-cache-testnet
      # Optional: restore from VolumeSnapshot
      # dataSource:
      #   kind: VolumeSnapshot
      #   name: zebra-snapshot-xyz
      #   apiGroup: snapshot.storage.k8s.io
```

- [ ] **Step 3: Add the hostPath pod volume**

In `templates/zebra-statefulset.yaml`, in the pod-level `volumes:` (after the `zebra-config` volume, lines 100-102), add:
```yaml
      volumes:
      - name: zebra-config
        configMap:
          name: {{ .Values.zebra.name }}-config
      {{- if .Values.zebra.volumes.data.hostPath }}
      - name: {{ .Values.zebra.name }}-data
        hostPath:
          path: {{ .Values.zebra.volumes.data.hostPath }}
          type: DirectoryOrCreate
      {{- end }}
```

- [ ] **Step 4: Skip the volumeClaimTemplate when hostPath is set**

In the same file, wrap the `volumeClaimTemplates:` block (lines 103-117) so it only renders without a hostPath. Change:
```yaml
  volumeClaimTemplates:
  - metadata:
      name: {{ .Values.zebra.name }}-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: {{ .Values.zebra.volumes.data.size }}
      {{- if .Values.zebra.storageClassName }}
      storageClassName: {{ .Values.zebra.storageClassName }}
      {{- end }}
      {{- with .Values.zebra.volumes.data.dataSource }}
      dataSource:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
```
to:
```yaml
  {{- if not .Values.zebra.volumes.data.hostPath }}
  volumeClaimTemplates:
  - metadata:
      name: {{ .Values.zebra.name }}-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: {{ .Values.zebra.volumes.data.size }}
      {{- if .Values.zebra.storageClassName }}
      storageClassName: {{ .Values.zebra.storageClassName }}
      {{- end }}
      {{- with .Values.zebra.volumes.data.dataSource }}
      dataSource:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- end }}
{{- end }}
```
(The final `{{- end }}` still closes the outer `{{- if .Values.zebra.enabled }}`.)

- [ ] **Step 5: Run the test — hostPath present, PVC absent**

Run:
```bash
helm template t . --set zebra.enabled=true \
  --set zebra.volumes.data.hostPath=/srv/zebra-state-cache-testnet \
  --show-only templates/zebra-statefulset.yaml | grep -E "hostPath:|path: /srv/zebra-state-cache-testnet|volumeClaimTemplates:"
```
Expected (PASS): `hostPath:` and `path: /srv/zebra-state-cache-testnet` present; `volumeClaimTemplates:` **absent**.

- [ ] **Step 6: Verify default still uses a PVC**

Run:
```bash
helm template t . --set zebra.enabled=true \
  --show-only templates/zebra-statefulset.yaml | grep -E "hostPath:|volumeClaimTemplates:"
```
Expected: `volumeClaimTemplates:` present; no `hostPath:`.

- [ ] **Step 7: Commit**

```bash
git add charts/zcash-stack/values.yaml charts/zcash-stack/templates/zebra-statefulset.yaml
git commit -m "Add optional hostPath cache source for zebra"
```

---

## Task 5: Scheduling hooks (nodeSelector / affinity / tolerations) on zebra + zaino

**Files:**
- Modify: `charts/zcash-stack/values.yaml` (`zebra` and `zaino`)
- Modify: `charts/zcash-stack/templates/zebra-statefulset.yaml` (line 18 area)
- Modify: `charts/zcash-stack/templates/zaino-statefulset.yaml` (line 17 area)

- [ ] **Step 1: Write the failing test**

Run:
```bash
helm template t . --set zebra.enabled=true --set zebra.nodeSelector.role=storage \
  --show-only templates/zebra-statefulset.yaml | grep -A1 "nodeSelector:"
helm template t . --set zaino.enabled=true --set zaino.nodeSelector.role=storage \
  --show-only templates/zaino-statefulset.yaml | grep -A1 "nodeSelector:"
```
Expected NOW (FAIL): both print nothing (no `nodeSelector:` rendered).

- [ ] **Step 2: Add the values**

In `values.yaml`, under `zebra:` (after `replicas: 1`, line 15) add:
```yaml
  nodeSelector: {}
  affinity: {}
  tolerations: []
```
And under `zaino:` (after `replicas: 1`, line 176) add the same three keys:
```yaml
  nodeSelector: {}
  affinity: {}
  tolerations: []
```

- [ ] **Step 3: Render the hooks in the zebra pod spec**

In `templates/zebra-statefulset.yaml`, after `enableServiceLinks: false` (line 18), insert:
```yaml
      enableServiceLinks: false
      {{- with .Values.zebra.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.zebra.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.zebra.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

- [ ] **Step 4: Render the hooks in the zaino pod spec**

In `templates/zaino-statefulset.yaml`, after the `enableServiceLinks: false` line (line 17), insert the same block but referencing `.Values.zaino`:
```yaml
      enableServiceLinks: false  # Prevent k8s service env vars conflicting with ZAINO_ config prefix
      {{- with .Values.zaino.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.zaino.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.zaino.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

- [ ] **Step 5: Run the test — hooks render**

Run:
```bash
helm template t . --set zebra.enabled=true --set zebra.nodeSelector.role=storage \
  --show-only templates/zebra-statefulset.yaml | grep -A1 "nodeSelector:"
helm template t . --set zaino.enabled=true --set zaino.nodeSelector.role=storage \
  --show-only templates/zaino-statefulset.yaml | grep -A1 "nodeSelector:"
```
Expected (PASS): both print `nodeSelector:` followed by `role: storage`.

- [ ] **Step 6: Verify defaults render no scheduling block**

Run:
```bash
helm template t . --set zebra.enabled=true --show-only templates/zebra-statefulset.yaml | grep -cE "nodeSelector:|affinity:|tolerations:"
helm template t . --set zaino.enabled=true --show-only templates/zaino-statefulset.yaml | grep -cE "nodeSelector:|affinity:|tolerations:"
```
Expected: `0` for both (empty `{}`/`[]` render nothing via `with`).

- [ ] **Step 7: Commit**

```bash
git add charts/zcash-stack/values.yaml charts/zcash-stack/templates/zebra-statefulset.yaml charts/zcash-stack/templates/zaino-statefulset.yaml
git commit -m "Add nodeSelector/affinity/tolerations hooks to zebra and zaino"
```

---

## Task 6: Bump chart version, lint, and combined state-mode smoke test

**Files:**
- Modify: `charts/zcash-stack/Chart.yaml` (line 5)
- Create (temp): `/tmp/state-zaino-values.yaml` (test only — not committed)

- [ ] **Step 1: Bump the chart version**

In `Chart.yaml`, change:
```yaml
version: 0.0.22
```
to:
```yaml
version: 0.0.23
```

- [ ] **Step 2: Lint the chart**

Run: `helm lint .`
Expected: `1 chart(s) linted, 0 chart(s) failed` (info-level messages OK).

- [ ] **Step 3: Write the combined test values file**

Write `/tmp/state-zaino-values.yaml`:
```yaml
zebra:
  enabled: false
  testnet: true
zaino:
  enabled: true
  rpcService: zebra.golden-zebra-state-testnet.svc
  rpcPort: "18232"
  nodeSelector:
    kubernetes.io/hostname: tekau
  zebraCache:
    enabled: true
    hostPath: /srv/zebra-state-cache-testnet
    mountPath: /var/cache/zebrad-cache
    readOnly: true
  config:
    backend: state
    zebraDbPath: /var/cache/zebrad-cache
```

- [ ] **Step 4: Render the full state-mode zaino and assert the whole seam**

Run:
```bash
helm template t . -f /tmp/state-zaino-values.yaml 2>&1 | tee /tmp/state-render.yaml | grep -E \
  "kind: StatefulSet|name: zebra-cache|readOnly: true|backend = 'state'|zebra_db_path = '/var/cache/zebrad-cache'|network = 'Testnet'|:18232|hostname: tekau|path: /srv/zebra-state-cache-testnet"
```
Expected (PASS), all present:
- exactly one `kind: StatefulSet` (zaino only — **no zebra StatefulSet**, since `zebra.enabled=false`),
- `name: zebra-cache` (x2), `readOnly: true`,
- `backend = 'state'`, `zebra_db_path = '/var/cache/zebrad-cache'`, `network = 'Testnet'`,
- `:18232` (init-rpc waits on the testnet port), `hostname: tekau`, `path: /srv/zebra-state-cache-testnet`.

Confirm no zebra StatefulSet:
```bash
grep -c "name: zebra$" /tmp/state-render.yaml
```
Expected: `0`.

- [ ] **Step 5: Clean up temp file and commit the version bump**

```bash
rm -f /tmp/state-zaino-values.yaml /tmp/state-render.yaml
git add charts/zcash-stack/Chart.yaml
git commit -m "Bump chart to 0.0.23 for state-mode cache hooks"
```

- [ ] **Step 6: Push the branch (do NOT merge to main yet)**

```bash
git push -u origin feat/state-mode-cache-hooks
```
Expected: branch pushed. Merging to `main` (which auto-releases the chart) is deferred to the Plan 2 handoff, after we've decided how Plans 2/3 consume the chart (released `main` vs the branch via a chart-ref).

---

## Self-Review (completed while writing)

- **Spec §5 coverage:** (1) hostPath cache source → Task 4; (2) `zebra.enabled` toggle → already exists in chart, no task needed; (3) `zaino.zebraCache` RO mount → Task 3; (4) value-driven `backend` → Task 1; (5) nodeSelector/affinity/tolerations → Task 5; (6) indexer gRPC 8230 → explicitly out of scope (spec §7.2 deferred). Plus a bug fix (Task 2, init-rpc port) and the mandatory `Chart.yaml` bump (Task 6).
- **Placeholders:** none — every code step shows the full before/after YAML and exact commands.
- **Naming consistency:** volume/mount name `zebra-cache`; values `zaino.zebraCache.{enabled,hostPath,mountPath,readOnly}`, `zaino.config.{backend,zebraDbPath}`, `zaino.rpcPort`, `zebra.volumes.data.hostPath`, `{zebra,zaino}.{nodeSelector,affinity,tolerations}` — used identically across tasks and the combined smoke test.
```
