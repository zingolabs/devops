# State-mode zaino against a shared golden zebra cache — Design

**Date:** 2026-08-18
**Status:** Approved design; open items pending verification (see §7)
**Repos touched:** `zingolabs/devops` (workflow, defs, docs), `zingolabs/zcash-stack` (Helm chart)

## 1. Problem & goal

We want ephemeral **state-mode** zaino deployments: a zaino that serves the bulk
of its read surface (blocks, transactions, confirmed tip/height, address
balances & UTXOs, treestate, subtree roots, `getblockchaininfo`) by reading
Zebra's on-disk finalized-state RocksDB **directly** via zaino's read-state
adapter (`zebra_state::init_read_only`), instead of over JSON-RPC.

The cache must be **live** — continuously updated by a healthy zebra — not a
frozen snapshot. Multiple ephemeral zainos should be able to read the same
live cache. For the queries the on-disk state cannot answer (mempool,
`send_transaction`, streaming chain tip), the zaino falls back to **RPC**
against that same zebra (zaino's composite read-state-first / RPC-fallback
router).

## 2. Decisions locked (with rationale)

1. **Topology: shared live zebra → many state zainos.** One healthy zebra syncs
   once and continuously; ephemeral zaino-only pods mount its live cache
   read-only. This is what makes state mode worth it for testing (one writer,
   many cheap readers).
2. **Dedicated `golden-zebra-state`, separate from `golden-mainnet`.** The
   existing golden uses topolvm-thin (RWO, LVM) for its snapshot-based ephemeral
   flow — its cache lives on an LV whose mount path is not a stable shareable
   path. The new one puts its cache on a shareable location instead. Both
   coexist.
3. **Shared cache = single-node shared local directory (hostPath on `tekau`).**
   The cluster has **no RWX storage class** (only `local-path` and
   `topolvm-thin`, both RWO). Rather than stand up NFS/CephFS and run a hot
   ~260Gi RocksDB **writer** over a network filesystem (discouraged, fragile),
   we keep everything on `tekau` and share a local cache directory. Local FS is
   exactly what RocksDB's read-state path wants. Cost: state zainos are pinned
   to `tekau`.
   - **Cluster reality (verified):** 2 nodes — `tekau` (control-plane) holds
     *all* topolvm storage; `arbeitspferd` (worker) has none. So both the writer
     and every reader must run on `tekau` regardless.
   - **Capacity constraint (verified, and a prerequisite):** a hostPath dir on
     tekau lands on the **root fs** (`/dev/nvme0n1p2`, ~341Gi free but **81%
     used**, shared with containerd/k3s) — **not safe** for a second ~260Gi
     cache. The shared cache therefore needs a **dedicated ~300–400Gi
     filesystem** mounted at the hostPath (a dedicated LV from `data_vg` if it
     has the physical extents, or a new disk). See §7.1 — this is a host-level
     prerequisite the design assumes is satisfied.
4. **Seed from existing golden.** A fresh mainnet sync is multi-day; we seed the
   new cache once from a consistent LVM snapshot of the existing golden zebra,
   then let the new zebra catch up the last blocks. Seed source and new zebra
   both run `zfnd/zebra:6.3.0` so the on-disk `state/vN` format matches.
5. **Ref-agnostic zaino config seam.** No shipping `zainod.toml` selector yet
   wires the read-only-open path (it exists in crate
   `zaino-source-zebra-readstate` on the `rc/0.8.0` branch, but the daemon's
   `backend=direct`/`state` currently runs its own writable syncer, not a
   read-only attach). So the infra exposes the mount + config keys as workflow
   inputs with sensible defaults and deploys whatever zaino ref reads them;
   end-to-end validation follows once a ref wires
   `ZebraReadStateAdapter::open`.

## 3. Architecture

```
 node: tekau
 ┌──────────────────────────────────────────────────────────────┐
 │  hostPath: /srv/zebra-state-cache   (shared local dir)        │
 │        ▲ RW                       ▲ RO         ▲ RO           │
 │   ┌────┴─────┐              ┌──────┴────┐  ┌────┴──────┐       │
 │   │ golden-  │  JSON-RPC    │ state     │  │ state     │  ...  │
 │   │ zebra-   │◄─8232(+8230)─│ zaino A   │  │ zaino B   │       │
 │   │ state    │  (non-state) │ (ns: …)   │  │ (ns: …)   │       │
 │   └──────────┘              └───────────┘  └───────────┘       │
 └──────────────────────────────────────────────────────────────┘
```

- **golden-zebra-state** (writer): mounts the hostPath **RW** at
  `/var/cache/zebrad-cache`; pinned to `tekau`; exposes JSON-RPC 8232
  (and indexer gRPC 8230 if needed — §7).
- **state zaino** (reader, per ephemeral namespace): no per-instance zebra;
  hostPath-mounts the shared dir **RO** at its `zebra_db_path`; pinned to
  `tekau`; RPC endpoints point at `zebra.golden-zebra-state.svc`.

## 4. Components

### 4.1 `golden-zebra-state` (new shared-cache zebra singleton)
- New ArgoCD-managed app: `domain/defs/golden-zebra-state.yaml` +
  `clusters/production/values/golden-zebra-state.yaml`.
- Same `zfnd/zebra:6.3.0` as `golden-mainnet`.
- Cache on a **fixed hostPath** on `tekau` (default `/srv/zebra-state-cache`),
  mounted **RW** at `/var/cache/zebrad-cache`.
- `nodeAffinity` → `tekau`.
- Exposes JSON-RPC **8232**; **indexer gRPC 8230** conditional on §7.2.
- Health endpoint 8080 as today.

### 4.2 Seed job (one-time bootstrap)
1. Take a consistent LVM `VolumeSnapshot` of the existing golden zebra cache
   (reuse `snapshot-golden`) — snapshot, not the live PVC, so the DB is
   internally consistent.
2. A copy `Job` pinned to `tekau` mounts the snapshot (topolvm RWO PVC from
   `dataSource`) **RO** and the new hostPath dir **RW**, then `rsync -a` the
   `state/` tree across.
3. Start `golden-zebra-state`; it opens the seeded cache and catches up.

### 4.3 state-mode ephemeral zaino (via `deploy-ephemeral`)
- `zebra.enabled=false` — no per-instance zebra.
- Zaino extra **RO hostPath mount** of the shared dir at its `zebra_db_path`
  (default `/home/zaino/.cache/zebra`); `nodeAffinity` → `tekau`.
- Zaino config: `backend=<state-backend>` (default `state`),
  `zebra_db_path=<mount>`, and RPC endpoints →
  `zebra.golden-zebra-state.svc:8232` (+ `:8230` if enabled).
- `init-rpc` readiness gate still waits on the shared zebra `:8232` (external
  but reachable) — kept.

## 5. Chart changes (`zcash-stack`, currently v0.0.22)

> Foreign repo, **no CLAUDE.md**. Conventions (inferred): one top-level values
> key per component; new behavior gated behind a values key with a
> behavior-preserving default; optional blocks via `{{- with … }}`; shared
> image pins under `global.images`. **Every chart change must bump
> `Chart.yaml: version`** — merges to `main` auto-publish via
> `chart-releaser-action`. All hooks below are confirmed **absent today** — each
> is a new additive, defaulted feature.

1. **hostPath cache source** for zebra: `zebra.volumes.data` gains a hostPath
   option as an alternative to the (currently strict) volumeClaimTemplate.
2. **`zebra.enabled`** toggle: skip rendering the zebra StatefulSet/Service.
   (Component `enabled` gating already exists as a chart idiom.)
3. **`zaino.zebraCache`** block: optional extra volume + mount on the zaino
   container — `{enabled, hostPath, mountPath (default /home/zaino/.cache/zebra),
   readOnly (default true)}`.
4. **Value-driven zaino `backend`** — currently hardcoded `'fetch'` in
   `zaino-configmap.yaml` line 8; make it a value (default `fetch` to preserve
   existing behavior).
5. **`nodeSelector`/`nodeAffinity`/`tolerations`** hooks on zebra + zaino —
   absent today; add to both StatefulSets.
6. **Indexer gRPC 8230** on zebra — absent today (zebra configmap renders no
   indexer section; golden runs plain JSON-RPC). Add only if §7.2 requires it;
   this is a real zebra-config feature, not a one-line toggle.

## 6. Workflow changes (`deploy-ephemeral.yaml`)

- New params:
  - `state-mode` (bool, default `false`)
  - `state-backend` (default `state`, overridable — the config seam)
  - shared cache hostPath + `golden-zebra-state` namespace/service as
    configurable defaults.
- When `state-mode=true`:
  - Skip all snapshot-clone steps (no per-instance cache).
  - Set helm values: `zebra.enabled=false`, `zaino.zebraCache.enabled=true`
    (+ hostPath, RO), `zaino.config.backend=<state-backend>`, `zebra_db_path`,
    RPC endpoints → `golden-zebra-state`, `nodeAffinity` → `tekau`.
  - Report block prints state-mode endpoints (zaino gRPC :8137; external zebra
    RPC).
- Non-state deploys unchanged.

## 7. Open items (resolve before/at implementation)

1. **Dedicated storage for the shared cache on `tekau` — HARD PREREQUISITE, host-level.**
   A hostPath on the root fs is unsafe (§2.3). We need a **dedicated
   ~300–400Gi filesystem mounted at the cache hostPath** on tekau. Resolution
   requires host access:
   - Check physical free extents: `vgs data_vg` / `lvs` on the tekau host.
   - If `data_vg` has room: create a dedicated LV, `mkfs`, mount at e.g.
     `/srv/zebra-state-cache` (persist in fstab). **Host action — user runs it**
     (privileged/host-level, outside GitOps).
   - If not: attach a new disk, or reconsider (NFS/RWX after all, accepting the
     writer-on-NFS tradeoff).
   The rest of the design assumes this mount exists; the workflow/chart just
   reference the path.
2. **Indexer gRPC (8230)** — does the target zaino ref's non-state fallback use
   JSON-RPC 8232 or the indexer gRPC 8230? Confirmed absent from both chart and
   golden zebra today. If gRPC is required, we must add zebra indexer config
   (confirm `zfnd/zebra:6.3.0` supports it) and expose 8230 on
   `golden-zebra-state`. If JSON-RPC suffices, no zebra change needed. Resolve
   against the specific ref (ties to §2.5).
3. **`state-backend` default value** — `state` vs `direct` vs a new selector
   name, pinned once we know which key the target zaino ref reads.

## 8. Cross-cutting concerns

- **Cleanup safety:** `/cleanup` deletes the ephemeral namespace only. The
  shared hostPath cache is node-local and MUST never be `rm`'d by cleanup.
- **Version coupling:** bumping `golden-zebra-state`'s zebra version requires
  reader-compatible zaino refs (on-disk `state/vN` format).
- **RO mount + RocksDB:** readers open the DB read-only (proven zebra
  read-state feature). If a read-only open ever needs a writable dir for a LOCK
  file under the RO mount, fall back to mounting the shared dir RW while relying
  on app-level read-only open.
- **Concurrency:** one live writer + N readers on one local FS — zaino's
  documented same-host design.

## 9. Docs & follow-up

- Update `.claude/deploy-ephemeral-reference.md` and `.claude/commands/deploy.md`.
- Add a devlog entry capturing this session's reasoning and the storage
  decision.
- Fix (separately) the latent double-`(default)` storage-class misconfig noted
  during investigation.

## 10. Implementation sequencing (for the plan)

1. Provision the dedicated cache mount on `tekau` (§7.1) — host-level gate,
   user action.
2. `zcash-stack` chart changes (§5) — additive, gated toggles; bump
   `Chart.yaml`.
3. `golden-zebra-state` def + values + seed job (§4.1, §4.2).
4. `deploy-ephemeral` state-mode path (§6) + docs (§9).
5. End-to-end validation with a zaino ref that wires the read-only-open path.
