# 2026-06-13 — Dashboard panels, deploy fixes, workflow back-compat

## Grafana domain config

Grafana share links were prepending `localhost`. Added `grafana.ini.server.domain` and `root_url` in kube-prometheus-stack values pointing to the Tailscale hostname (`monitoring-kube-prometheus-stack-grafana.vaquita-altair.ts.net`).

## Sync throughput dashboard panels

Added a "Sync Throughput" row to the Zaino Sync dashboard with three panels:
- Transactions/sec (`rate(zaino_sync_transactions_total[5m])`)
- Shielded Actions/sec (Sapling + Orchard as separate series)
- Combined Shielded Throughput (sum of both pools)

These use the new metrics from PR#1242.

## Cluster cleanup

Surveyed all deployments — found 6 dead namespaces with PVCs consuming ~2,350 Gi and crosslink taking ~220 Gi. Cleaned up to free ~2,570 Gi total. Storage exhaustion was blocking new PVC provisioning.

## extraEnv helm issue

The `extraEnv` field in ephemeral values isn't reaching pods through helm. Root cause is somewhere in the zcash-stack chart. Every deploy still requires manual patching of env vars and service ports after helm install. Ongoing issue.

## Build workflow back-compat

PR#1238 uses an older Dockerfile with `ARG NO_TLS=true` instead of `ARG CARGO_FEATURES`. The workflow now passes both `CARGO_FEATURES` and `NO_TLS=true` as build args for backwards compatibility with older branches.

## Force-build flag

Added `force-build` parameter to both `build-zaino` and `deploy-ephemeral` workflows. When `true`, the `check-image` step skips the Docker Hub cache check, forcing a rebuild. Needed when pushing same tag with different build args (e.g. fixing feature flags).

Learned: `imagePullPolicy: IfNotPresent` means nodes cache images by tag. After force-rebuilding and pushing the same tag, pods need `imagePullPolicy: Always` or a tag change to pick up the new image.
