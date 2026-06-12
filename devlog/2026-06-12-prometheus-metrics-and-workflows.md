# 2026-06-12 — Prometheus metrics integration, workflow improvements

## Prometheus metrics on zaino

The `trial/prometheus-metrics` branch merged to dev (PR#1216). Zaino now exposes a `/metrics` endpoint when built with `no_tls_with_prometheus` cargo feature and configured with `ZAINO_METRICS_ENDPOINT=0.0.0.0:9998`.

Metrics include `zaino.sync.finalized_height`, `zaino.sync.target_height`, and others — exactly what we needed instead of the bash log scrapers.

## Build workflow: cargo-features

Switched all build workflows from `NO_TLS=true` to `CARGO_FEATURES=no_tls_with_prometheus`. The Dockerfile already supported `CARGO_FEATURES` as a build arg that takes precedence over `NO_TLS`. Image tags now use the feature suffix (e.g. `dev-no-tls-with-prometheus`).

## Ephemeral values: metrics by default

Added `ZAINO_METRICS_ENDPOINT` env var and `metricsPort: 9998` to `ephemeral-mainnet.yaml`. New deploys get metrics automatically. Added `metrics=true/false` toggle for deploying older refs that don't support it:

```
# Default (with metrics):
argo submit ... -p namespace=preview-1221 -p ref=<sha>

# Older ref (no metrics):
argo submit ... -p namespace=test-old -p zaino-tag=0.3.1-no-tls -p metrics=false
```

## Snapshot metadata gaps (devops#4)

The `snapshot-golden` workflow labels snapshots with metadata but the height label is always empty (metrics scrape failing). Missing state version and network upgrade labels. This caused us to deploy pre-NU6.2 snapshots with post-NU6.2 zebras that forked. Filed devops#4.

## Chart image hash bug (devops#3)

The zcash-stack chart double-prefixes `sha256:` when the values include it. Filed devops#3.

## Ongoing: PR#1221 preview

Deployed `preview-1221` ("Rc 0.4.0 slow sync fixed data window") with prometheus metrics enabled from scratch. Monitoring sync speed via Grafana instead of bash scrapers. This is the first deploy where we can watch the sync curve in real-time on a dashboard.
