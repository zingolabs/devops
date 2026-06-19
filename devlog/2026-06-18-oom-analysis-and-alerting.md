# 2026-06-18 — OOM analysis, persistence regression, golden updates, alerting infra

## 0.5.0-rc.1 and PR#1238 OOM analysis

Deployed both `0.5.0-rc.1` and PR#1238 (`rc_0_4_0_slow_sync_plus_updates`) against zebra 5.1.0 on mainnet. Both OOM at 16 GiB, but the failure modes are completely different:

**PR#1238**: Syncs all blocks to chain tip successfully. OOMs during "rebuilding txout-set accumulator" post-sync. Retains LMDB state across crashes — restarts only re-sync the last few blocks. ~13 min crash cycles, 31 restarts over 28 hours.

**0.5.0-rc.1**: Never reaches chain tip. OOMs within 74 seconds of starting, at height ~108k (only 7k past the 101k golden snapshot baseline). Zero committed batches, zero accumulator rebuilds. 57 restarts in 5 hours, each starting from 101k — no progress retained.

## Persistence regression root cause

Diffed the two branches. 0.5.0-rc.1 includes PRs #1249 and #1250 which introduced a background sync architecture with `EphemeralMode`/`EphemeralReference` routing. When `sync_to_height` exceeds `LONG_RUNNING_SYNC_THRESHOLD`, sync is spawned as a background task. On OOM crash, the spawned task's uncommitted work is lost entirely.

PR#1238 writes synchronously — each LMDB batch commit is durable and survives crashes. The `db` → `finalised_source` rename in module paths is cosmetic; the real change is the router layer (926 lines in `router.rs`).

Filed upstream: [#1260](https://github.com/zingolabs/zaino/issues/1260) (OOM), [#1261](https://github.com/zingolabs/zaino/issues/1261) (persistence regression).

## Golden deployment updates

Bumped both golden deploys via GitOps:
- golden-mainnet: zaino 0.2.0-rc.6 → 0.4.1, zebra 5.1.0 → 5.2.0
- golden-testnet: zaino 0.2.0-rc.6 → 0.4.1, zebra default → 5.2.0

## zcash-stack UID fix

Golden-testnet was crashlooping due to UID mismatch — zaino 0.4.x runs as UID 1000 but the chart's init-perms container was chowning to 2003. ArgoCD selfHeal kept reverting imperative patches. Fixed by making `zaino.runAsUser` a configurable helm value (defaulting to 1000) in the zcash-stack chart and pushing to main.

## Alerting infrastructure (in progress)

Scaffolded Signal-based alerting:
- **PrometheusRule CRD** with alerts: ZainoOOMKilled, ZainoHighRestarts, ZainoPodNotReady, ZainoSyncStalled, ZainoSyncGapLarge
- **signal-bridge** platform component: signal-cli-rest-api + alertmanager-webhook-signal
- **sealed-secrets** controller for encrypting phone numbers (public repo)
- Alertmanager route config for `app=zaino` → Signal webhook

Blocked on JMP.chat phone number registration. Using XMPP (profanity + xmpp.is) to get a virtual number via Cheogram without PII.
