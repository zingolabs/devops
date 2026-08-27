# 2026-08-20/21 — State-mode zaino against a shared live golden-zebra cache: design, capacity dig, chart hooks

Continuation of the readstate-mode direction flagged in [devops#6]. Goal: infra to deploy
ephemeral **state-mode** zainos that read a **shared, live** golden-zebra RocksDB cache
directly (fast historical/state reads) and fall back to that zebra's RPC for the rest.
Brainstorm → spec → Plan 1 (chart) implemented + merged. Design pivoted mid-session from
testnet-first to **mainnet-direct** after a storage dig freed ~612G on tekau.

## The load-bearing discovery — there are TWO "state modes" in zaino
- **`backend = "direct"` (alias `"state"`) — the shipping daemon path.** Despite the name it does
  NOT read-only-attach to a running zebra. It spawns zaino's *own* zebra syncer
  (`init_read_state_with_syncer`) that pulls blocks over the validator's gRPC and **writes them into
  zaino's own DB copy** at `zebra_db_path`. Needs write + a live zebra gRPC. Not "mount a RO copy".
- **`ZebraReadStateAdapter::open(cache_dir, network)` — the true read-only reader.** Opens zebra's
  finalized-state RocksDB read-only via `zebra_state::init_read_only`, no syncer, no RPC. New crate
  `zaino-source-zebra-readstate` on branch **`rc/0.8.0`** (0.8.0-rc.3). This is our mental model —
  but it is **not wired to any `zainod.toml` selector yet**; only exercised via a doc example.
- **Consequence → ref-agnostic seam.** The infra can't assume a config key exists. It provides the
  mount + config params (`backend`, `zebra_db_path`) and deploys whatever zaino ref reads them;
  end-to-end validation waits on a ref that actually calls `open()`.

## What state-mode serves from the cache vs. still needs the validator
- **Cache-dir alone (no validator):** blocks, transactions, confirmed tip/height, address
  balances & UTXOs, treestate, subtree roots, `getblockchaininfo`.
- **Needs RPC fallback to zebra:** mempool, `send_transaction`, streaming `SubscribeChainTip`
  (the read-only open yields no `ChainTipChange` — a poller sees the tip advance, a subscriber
  doesn't), and `GetAddressDeltas`. zaino's composite router is readstate-first / RPC-fallback.
- So a state zaino still wires RPC to the same zebra for the non-state surface.

## Storage: why a shared *live* cache is hard, and the chosen model
- **A separate ephemeral pod can't share golden's live volume.** RWO access mode (one node),
  topolvm is node-local ext4 (not a cluster FS — two mounts corrupt), and thin snapshots are
  point-in-time. All three independently forbid it. Live-share needs either co-location on one
  local FS, or an RWX network FS.
- **No RWX class exists** (only `local-path` + `topolvm-thin`, both RWO). Standing up NFS/CephFS
  would clear the access-mode wall but puts a hot ~260G RocksDB **writer** on a network FS
  (discouraged/fragile). Rejected.
- **Chosen: single-node shared hostPath on tekau.** Local FS = exactly what rocksdb's read-state
  wants. All pods pinned to tekau (already the only storage node). One live zebra writer, many
  RO readers. Cross-namespace sharing works because hostPath is node-scoped (a PVC is not).

## Capacity dig → the mainnet-direct pivot (the session's turn)
- Cluster is 2 nodes: **tekau** (control-plane) holds *all* topolvm storage; **arbeitspferd**
  (worker) none. Two physical disks on tekau: **nvme1n1** (1.8T) = the topolvm `data_vg`;
  **nvme0n1p2** = the ext4 **root fs**.
- topolvm side is tight: VG free **~122G**, thin pool 1.70T at **~70%** physical (shared substrate
  for every PVC + both golden zebras — filling it corrupts all thin vols). No clean mainnet slot.
- Root fs was **81% full** — but the 1.3T was **`/home/pua`** (uid 1001), not system: **517G**
  rootless podman storage, **265G** `zebra-mainnet-seed`, **213G** `zas_zainos`, **58G** zaino
  mainnet data, plus a defunct root `/state/v27` (**79G**, mtime **2025-09-11**, v27 = pre-Ironwood
  format). Evidence pua had hand-prototyped state-mode on the host.
- **Verified safe before deleting:** the live `zebrad`/`zainod` in host `ps` are the **k8s pods**
  (cwd `/home/zebra`, `cache_dir=/var/cache/zebrad-cache` → `state/v28/...` on their topolvm PVCs,
  confirmed via `/proc/<pid>/root/etc/zebrad/zebrad.toml` + lsof). Nothing held the target dirs
  open. (Note: `fuser -m` is useless here — with everything on one root fs it reports *all* root-fs
  users, not per-dir refs. The process/lsof/mtime evidence is what mattered.)
- **Reclaimed ~612G** (the three chain-data dumps + `/state`; left the 517G podman store + a 21G
  `/home/pua/zebra` source checkout alone). Root fs **341G→953G free (81%→46%)**. Ran as a
  hand-off script — the auto-mode classifier (correctly) blocks bulk remote `rm -rf`.
- **Pivot: mainnet-direct.** Testnet-first only existed to dodge capacity. With 953G free on the
  **root disk** (a *different* physical disk from the topolvm pool → IO-isolated, and no thin-pool
  risk), the mainnet cache is just a **plain hostPath dir** `mkdir /srv/zebra-state-cache-mainnet`.
  **No LV cutting, no testnet detour.** Seed from the live k8s `golden-mainnet` snapshot (current +
  consistent) rather than pua's stale on-host seed.

## Plan 1 — zcash-stack chart hooks (DONE, merged to main, chart 0.0.23)
All additive, gated, defaults preserve current render; each verified with `helm template`/`lint`.
- Value-driven zaino `backend` + `zebra_db_path` (were hardcoded `fetch` / `/home/zaino/.cache/zebra`).
- **Latent bug fixed:** `init-rpc` derived its wait port from `zebra.enabled`, so a zaino pointed at
  an *external* testnet zebra would wait on `:8232` while testnet listens on `:18232`. Added
  `zaino.rpcPort` override.
- `zaino.zebraCache` — optional **read-only** hostPath mount of the shared cache.
- `zebra.volumes.data.hostPath` — optional hostPath cache source (omits the volumeClaimTemplate).
- `nodeSelector`/`affinity`/`tolerations` on zebra + zaino (were absent). `zebra.enabled` already
  existed. Indexer-gRPC :8230 deliberately deferred.
- Combined state-mode render verified: 1 StatefulSet (zaino only, zebra absent), RO zebra-cache mount,
  `backend='state'`, testnet ports, tekau affinity.
- **Consumption is via `type: helm-git`** (ArgoCD pulls the chart from git `main`); the "Release
  Charts" Actions workflow has in fact **never run** (0 runs, no gh-pages) — irrelevant, since
  nothing consumes a packaged release. So merging to main *is* the release for our purposes.

## Design decisions locked
- Shared live zebra → many state zainos; new **`golden-zebra-state`** (mainnet, `zfnd/zebra:6.3.0`,
  hostPath cache on root disk, nodeAffinity tekau, exposes :8232) **separate** from `golden-mainnet`.
- One-time **seed** from a `golden-mainnet` LVM snapshot (matching zebra version → no reindex).
- **Ref-agnostic config seam** (see above). Cleanup must never `rm` the shared hostPath cache.

## Open items
- **Indexer gRPC :8230** — does the target zaino ref's non-state fallback speak JSON-RPC 8232 or the
  indexer gRPC 8230? If the latter, `golden-zebra-state` must run zebra's indexer (confirm 6.3.0
  supports it; golden doesn't run it today). Resolve against the ref.
- **`backend` selector value** (`state` vs `direct` vs new) — pin against the ref that wires `open()`.
- Root-fs cache growth has no hard cap (plain dir) — monitor; optionally quota/LV later.
- Double-`(default)` storage-class misconfig (both `local-path` and `topolvm-thin` flagged default).

## Artifacts
- Spec: `docs/superpowers/specs/2026-08-18-state-mode-zaino-shared-cache-design.md` (devops
  `d93b901`, `9a68db3`, `16f8528` mainnet-pivot).
- Plan 1: `docs/superpowers/plans/2026-08-20-state-mode-zaino-chart-changes.md` (devops `5d43829`).
- zcash-stack (branch `feat/state-mode-cache-hooks`, FF-merged to `main` @ `4167db7`): commits
  `892699c` backend/db-path, `3197ef3` rpcPort, `8d343e8` zebraCache, `2466439` zebra hostPath,
  `d0e6917` scheduling hooks, `4167db7` chart 0.0.23.
- Reclaimed ~612G on tekau (`/home/pua/{zebra-mainnet-seed,zas_zainos,.local/share/zaino/mainnet}`,
  `/state`). Root fs 46% used.

## 2026-08-26 — Plan 2 deployed: golden-zebra-state live on the seeded hostPath
- Staged straight to devops `main` (ArgoCD reads `main`; user is sole contributor, direct-push OK):
  seed workflow first → `argo submit seed-zebra-state-cache` → verify → then the app def. Pushed via a
  throwaway worktree off `origin/main` (cherry-picks `ed4893c` seed, `089dee6` def) to avoid disturbing
  unrelated WIP in the tree. (SSH-agent died mid-session — push needs `ssh-add`; keys never touched.)
- **Seed worked cleanly:** `seed-zebra-state-cache` succeeded in ~4 min (copy step 3m for ~260G, local
  NVMe). hostPath `/srv/zebra-state-cache-mainnet` = **261G**, `state/v28/mainnet`, 17,719 `.sst`, uid 2001.
  Crash-consistent snapshot of a live `zebra-data-zebra-0`, no quiesce — rocksdb opened it fine.
- **Zebra opened the seed, not genesis:** `initial disk state version: 28.0.0`,
  `Opened Zebra state cache at /var/cache/zebrad-cache/state/v28/mainnet`, restored non-finalized backup.
  App Synced/Healthy, `zebra-0` on tekau, Service **`zebra.golden-zebra-state.svc:8232`** (+8080).
- **Peer contention (confirms [devops#6], but degraded not dead):** only `handshake_success_total=2`
  (23 errors — many `ConnectionReset`/`ObsoleteVersion`). Root cause is twofold: shares tekau's egress
  IP with golden-mainnet (`max_connections_per_ip=1`, remote-enforced) AND tekau's filtered WiFi degrades
  outbound. Result: cache tracks tip but **holds ~30 blocks (~40 min) behind**, advancing slowly (bounded).
- **Chart hooks all worked in the wild:** `zebra.volumes.data.hostPath` (PVC omitted), `zebra.nodeSelector`
  (tekau), zebra-only render (zaino/lwd/zcashd off). Plan 1 validated end-to-end.

### Ensuring a fully-healthy syncing golden-zebra-state (open — user wants this for readstate dev)
Must stay on tekau (hostPath cache there, shared with state zainos), so it can't escape tekau's IP/network
by rescheduling. Candidate fixes:
- **(A) In-cluster peer with golden-mainnet — preferred.** Point golden-zebra-state's `initial_mainnet_peers`
  at golden-mainnet's zebra P2P (`:8233`), so it syncs blocks *intra-cluster* from the healthy node. Internal
  source is the pod IP (unique), so `max_connections_per_ip` doesn't bite, and it bypasses the filtered WiFi
  entirely. Needs a small chart hook to template zebra initial peers; validate zebra will single-peer sync.
- **(B) Clean distinct egress IP** via a Tailscale exit node / small VPS — fixes per-IP + bad-network at once,
  but new infra. The "proper" [devops#6] fix.
- **(C) Periodic re-seed mirror** — no golden-zebra-state sync; a cron re-runs `seed-zebra-state-cache` to snap
  the cache back to tip. Simple, but static (staleness = interval) and less faithful for readstate dev.
- **Plan-3 note:** state zainos' RPC fallback (mempool/tx/tip) should target **golden-mainnet's** healthy
  zebra, reading the cache from golden-zebra-state.

**RESOLVED (2026-08-27) — option A shipped and works.** Chart **0.0.24** added two gated hooks:
`zebra.initialPeers` (renders `initial_mainnet_peers` in zebrad.toml) and `zebra.service.p2p` (exposes
8233 on the Service). golden-mainnet values set `service.p2p: true`; golden-zebra-state values set
`initialPeers: ["zebra.golden-mainnet.svc:8233"]`. After a STS restart (configmap change doesn't
auto-reload), golden-zebra-state logs **`finished initial sync to chain tip, using gossiped blocks
sync_percent=100.000% remaining_sync_blocks=0`** and tracks new blocks in real time — syncing
intra-cluster from golden-mainnet, immune to the WiFi/IP problems. The shared cache is now live at tip.

## Follow-ups
- [x] `mkdir /srv/zebra-state-cache-mainnet` on tekau — done.
- [x] **Plan 2** — `golden-zebra-state` + seed — deployed; zebra opened the seed near tip.
- [x] **Ensure golden-zebra-state syncs healthily** — done via option A (in-cluster peer, chart 0.0.24); at tip.
- [x] **Plan 3** — `deploy-ephemeral` state-mode path shipped (chart 0.0.24). New params `state-mode`,
  `state-backend` (default `state`), `state-cache-hostpath`, `state-rpc-service`
  (default **`zebra.golden-zebra-state.svc`** — same node as the cache, single source of truth, no skew),
  `state-rpc-port`. `state-mode=true` → skips snapshot cloning, `zebra.enabled=false`, RO-mounts the shared
  cache, pins zaino to tekau, sets `backend`/`zebra_db_path`, RPC-falls-back to the read zebra. Render
  verified (0 zebra STS, RO zebra-cache, backend=state, self-RPC). Docs updated (reference + /deploy).
- [x] **End-to-end VALIDATED (2026-08-27) with zaino 0.9.0-rc.1, `backend=direct`.** Correcting an earlier
  wrong conclusion: the shipping `direct`/`state` backend DOES open Zebra's finalized cache **read-only** —
  `init_read_state_with_syncer` → `spawn_init_read_only` → RocksDB **secondary** mode (`open_cf_descriptors_as_secondary`),
  live-follows the primary, writes only a per-pod scratch tempdir; `delete_old_database:true` is a no-op in RO.
  So the shared-RO-cache design is correct and needs no zaino change. (My first trace stopped at the zaino layer;
  the truth is in the zebra-state dep. User's instinct was right.)
  Two operational fixes made it run (chart **0.0.25**):
  1. **uid mismatch** — Zebra writes the cache 0600 as uid 2001; zaino ran as a different uid → `PermissionDenied`
     reading the DB version file. Fix: `zaino.applyRunAsUser` → run zaino container as uid **2001**.
  2. **indexer gRPC** — the tip syncer connects to Zebra's indexer gRPC (`validator_grpc_listen_address`), NOT
     JSON-RPC. Fix: `zebra.indexer` → `indexer_listen_addr = 0.0.0.0:8230` + expose the port. Stock `zfnd/zebra:6.3.0`
     serves it via config (the `indexer` cargo feature does NOT gate the gRPC server in 6.x) — no custom image.
  Rendered zaino config matches the canonical `zainod-bench-mainnet.toml` exactly (backend=direct, zebra_db_path,
  validator_grpc :8230, validator_jsonrpc :8232). Deploy `state2-cd28040`: zaino READY, 0 restarts, gRPC Ready on
  :8137, reading the shared RO cache, tip advancing. **Full pipeline proven end-to-end.**
  **PROVEN with a real gRPC query (2026-08-27):** `GetLightdInfo` on the state-mode zaino returned live
  mainnet data — `chainName=main, blockHeight=3462874 (at tip), zcashdSubversion=/Zebra:6.3.0/, upgradeName=NU6.3`.
  A zaino-only pod, no per-instance zebra, serving a wallet client off the shared RO cache. Stable, 0 restarts.
- **Third bug (deploy-ephemeral `fix-permissions` step):** it hardcodes
  `kubectl patch sts zaino ... chown -R 1000:1000 /home/zaino` and runs it AFTER helm — stomping the
  chart's correct `chown 2001` back to 1000, so the uid-2001 container couldn't open its own LMDB index
  (`LMDB database error: Permission denied`, PERSISTENT mode). This is why helm's stored manifest said 2001
  but the live STS said 1000. Fix: **gate `fix-permissions` with `when: state-mode != 'true'`** (the chart's
  init-perms already chowns to runAsUser=2001 in state mode). Lesson: post-helm imperative patches in the
  workflow silently override chart values — check them when a live resource disagrees with `helm get manifest`.
- [ ] Optional: `ephemeral_finalised_state` — zaino still builds its own chain-index (`fs_mode=ephemeral(syncing)`,
  fast from the local cache) before fully-historical queries; tip queries work immediately. Set `false` to persist
  the index across restarts (bench-mainnet does); `true` for lightest disposable instances.
- [ ] Optional: clean redeploy (fresh ns) to confirm the fixed pipeline needs no manual patch (the hand-patch
  reproduced exactly what the gated workflow now does, so it's validated, but a from-scratch run is the final tick).
- [ ] Decide indexer-gRPC :8230 + `backend` selector against that ref.
- [ ] Optional: cap the root-fs cache (quota/LV) so growth can't threaten k3s.
