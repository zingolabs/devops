# 2026-06-11 — Sync speed regression bisect

## Finding: 60x sync regression in 0.4.x

zaino 0.3.1 syncs at 300-500 blocks/sec. zaino 0.4.0-rc.2 syncs at ~5 blocks/sec. Bisected to PR#1112 (`get_tx_out_set_info`) which added a per-block UTXO accumulator that runs synchronously in the write path.

The accumulator reads/updates LMDB on every block write. The previous-output resolution was a full table scan of the txids table — O(n) per input, effectively quadratic over time.

## deploy-ephemeral parameterization

Overhauled the `deploy-ephemeral` workflow to support:
- `network` param (mainnet/testnet) with per-network values templates
- `ref` param that triggers `build-zaino` (builds if image doesn't exist on Docker Hub)
- `zaino-tag` for pre-built images
- `zebra-tag`, `zebra-snapshot`, `zaino-snapshot` overrides
- `use-zaino-cache` for cached vs fresh zaino deploys
- Auto-resolves latest golden snapshots per network

Usage: `argo submit --from workflowtemplate/deploy-ephemeral -n argo -p namespace=test -p ref=<sha> -p zebra-tag=5.1.0`

This enabled rapid deployment of arbitrary commits for bisecting.

## Benchmark results

Deployed 4 PRs side by side with dedicated zebras and sync speed monitors:

| Height range | 0.3.1 (ref) | PR#1207 (txid index) | PR#1214 (perf benchmarks) | PR#1215 (slow sync fix) | PR#1218 (instant response) |
|---|---|---|---|---|---|
| 0-50k | ~400 | 266 | 449 | 293 | 103 |
| 50k-100k | ~300 | 169 | 287 | 177 | 37 |
| 106k-110k | ~300 | 4.5 | 31 | 3.8 | 0.9 |
| 110k+ | ~250 | 29 | 131 | 18 | — |

PR#1214 is the clear winner. All 0.4.x versions hit a cliff at block ~106k that 0.3.1 doesn't have.

## The 106k cliff

Reproducible across all deploys with the accumulator. Not caused by:
- Zebra contention (confirmed with dedicated fully-synced zebra)
- Resource limits (no CPU limits, nodes had headroom)
- Crosslink miners (scaled down, still slow)

The cliff is height-specific — speed recovers after ~108k but at a lower baseline. Block 106,500 has ~103 transactions (double normal) but that alone doesn't explain 100x slowdown.

## Storage pressure

Hit 5.3 TiB across 29 topolvm PVCs at peak (8 zebra snapshots at 350Gi each). Ran out of storage deploying bisect-1218. Need better lifecycle management for ephemeral deploys.

## Golden snapshot

Took a fresh golden-mainnet snapshot after zebra 5.1.0 reached the tip post-NU6.2. All new `deploy-ephemeral` calls auto-resolve to this snapshot.
