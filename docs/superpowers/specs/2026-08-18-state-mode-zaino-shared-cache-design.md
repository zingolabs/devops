# State-mode zaino against a shared golden zebra cache — Design

**Date:** 2026-08-18
**Status:** Approved; chart hooks landed (Plan 1 merged); capacity solved by reclaiming ~612G on tekau → **mainnet-direct** (no testnet phase). See §2.6, §7.1.
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
   - **Capacity (resolved 2026-08-20):** tekau has two disks — `nvme1n1`
     (1.8 TiB) is entirely the topolvm pool; `nvme0n1p2` is the ext4 **root fs**.
     Root fs was 81% full, but ~612G of stale chain caches (a defunct host
     `/state/v27`, and pua's `zebra-mainnet-seed` / `zas_zainos` / zaino mainnet
     dumps) were reclaimed, leaving **~953 GiB free (46%)**. The mainnet cache
     therefore lives as a **plain hostPath directory on the root disk**
     (`/srv/zebra-state-cache-mainnet`) — no LV, and on a *different physical
     disk* from the topolvm pool, so the rocksdb writer is IO-isolated from the
     PVC workloads and never touches the thin pool. (Watch root-fs headroom as
     the cache grows; ~953G leaves years of runway for a ~260G mainnet cache.)
4. **Seed from existing golden.** A fresh mainnet sync is multi-day; we seed the
   new cache once from a consistent LVM snapshot of the existing golden zebra,
   then let the new zebra catch up the last blocks. Seed source and new zebra
   run the **same zebra version** so the on-disk `state/vN` format matches
   (`golden-mainnet` is `zfnd/zebra:6.3.0`; confirm `golden-testnet`'s for
   Phase 1).
5. **Ref-agnostic zaino config seam.** No shipping `zainod.toml` selector yet
   wires the read-only-open path (it exists in crate
   `zaino-source-zebra-readstate` on the `rc/0.8.0` branch, but the daemon's
   `backend=direct`/`state` currently runs its own writable syncer, not a
   read-only attach). So the infra exposes the mount + config keys as workflow
   inputs with sensible defaults and deploys whatever zaino ref reads them;
   end-to-end validation follows once a ref wires
   `ZebraReadStateAdapter::open`.
6. **Mainnet-direct (revised 2026-08-20).** The original plan was testnet-first,
   forced by a capacity crunch. Reclaiming ~612G on the root disk (§2.3) removed
   that constraint, so we go straight to **mainnet**: `golden-zebra-state` runs
   mainnet, cache in a hostPath dir on the root fs, seeded from the live k8s
   `golden-mainnet` (a current, consistent LVM snapshot — better than any stale
   on-host seed). No testnet detour, no LV surgery. The chart hooks (Plan 1) are
   network-parametric, so nothing about them changes for mainnet.

## 3. Architecture

```
 node: tekau
 ┌──────────────────────────────────────────────────────────────┐
 │  hostPath: /srv/zebra-state-cache-mainnet  (root disk)        │
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

### 4.1 `golden-zebra-state` (new shared-cache zebra singleton — mainnet)
- New ArgoCD-managed app: `domain/defs/golden-zebra-state.yaml` +
  `clusters/production/values/golden-zebra-state.yaml`.
- Zebra image = **same version as `golden-mainnet`** (`zfnd/zebra:6.3.0`) — must
  match so the on-disk `state/vN` format aligns and no reindex triggers on first
  open.
- Cache on a **fixed hostPath** on `tekau` (`/srv/zebra-state-cache-mainnet`, on
  the root disk `nvme0n1`), mounted **RW** at `/var/cache/zebrad-cache`.
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

1. **Cache directory on `tekau` — trivial host step (resolved).**
   No LV needed: root fs now has ~953 GiB free (§2.3). Just
   `mkdir -p /srv/zebra-state-cache-mainnet` on tekau (owned so the zebra
   container uid 2001 can write — the chart's `set-permissions` init `chown`s it
   on first start, so an empty dir suffices). The chart/workflow reference this
   path via `zebra.volumes.data.hostPath` and `zaino.zebraCache.hostPath`.
   Operational note: monitor root-fs usage as the cache grows.
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

## 10. Implementation sequencing (mainnet-direct)

1. ~~`zcash-stack` chart changes (§5)~~ — **DONE (Plan 1, merged to main).**
2. `mkdir /srv/zebra-state-cache-mainnet` on tekau (§7.1) — trivial host step.
3. **Plan 2:** `golden-zebra-state` (mainnet) def + values + seed job from
   `golden-mainnet` (§4.1, §4.2).
4. **Plan 3:** `deploy-ephemeral` state-mode path (§6) + docs (§9).
5. End-to-end validation with a zaino ref that wires the read-only-open path
   (resolve §7.2 indexer-gRPC + §7.3 backend selector against that ref).
