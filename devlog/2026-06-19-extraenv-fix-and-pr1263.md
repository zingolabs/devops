# 2026-06-19 — extraEnv fix, PR#1263 deployment prep

## extraEnv helm array → map conversion

The `extraEnv` field in the zcash-stack chart was defined as a YAML array (`[{name, value}]`). Helm replaces arrays wholesale instead of merging them — any `--set` on an array index wipes the rest. This was the root cause of the long-standing issue where env vars set in ephemeral-values.yaml never reached pods (documented in 2026-06-13 devlog). Every deploy required manual patching.

Fixed by converting `extraEnv` from an array to a map:

```yaml
# before
extraEnv:
  - name: ZAINO_METRICS_ENDPOINT
    value: "0.0.0.0:9998"

# after
extraEnv:
  ZAINO_METRICS_ENDPOINT: "0.0.0.0:9998"
```

Helm deep-merges maps, so `--set zaino.extraEnv.NEW_KEY=value` now adds a key without disturbing existing entries. The statefulset template iterates with `range $name, $value` instead of `range .` over array items.

Changes across two repos:
- **zcash-stack**: `values.yaml` (default `extraEnv: {}`), `zaino-statefulset.yaml` (map iteration)
- **devops**: `ephemeral-values.yaml` (mainnet entries converted to map), `deploy-ephemeral.yaml` (metrics=false uses `{}` instead of `null`)

## New zaino-env workflow parameter

Added `zaino-env` parameter to `deploy-ephemeral` workflow. Accepts comma-separated `KEY=VALUE` pairs, parsed in the helm-install step into individual `--set zaino.extraEnv.KEY=VAL` flags. These merge on top of whatever the base values file already defines.

Usage:
```bash
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=test-1263 \
  -p ref=<sha> \
  -p zaino-env="ZAINO_STORAGE__DATABASE__SYNC_WRITE_BATCH_SIZE=8,ZAINO_STORAGE__DATABASE__SYNC_CHECKPOINT_INTERVAL=300"
```

## PR#1263 — sync hotfixes config fields

PR#1263 (`rc_0_5_0_sync_hotfixes`) adds two new `[storage.database]` TOML config fields:

- **`sync_write_batch_size`** (GiB, default 32): memory budget for sync batches and accumulator rebuild. This is the OOM fix — the accumulator now auto-shards to stay within budget instead of loading the entire spent set into one HashSet.
- **`sync_checkpoint_interval`** (seconds, default 300): max time between flush commits. Previously hardcoded at 60s.

These can be overridden via env vars using zaino's `config-rs` layering (`ZAINO_` prefix, `__` separator for nesting). Old refs that don't have these struct fields ignore the env vars harmlessly. This is why we route them through `extraEnv` rather than modifying the TOML configmap template (which would break deploys of older refs).

Planning two test deployments with different batch sizes (2 GiB and 8 GiB) against 16 GiB pods to find the right trade-off between OOM safety and sync throughput.

## Deployment debugging

Three bugs hit during the first deploy attempts:

1. **IFS leak**: the `zaino-env` parsing loop set `IFS=','` but never restored it. The entire `$OVERRIDES` string was then treated as one word by the unquoted expansion in the helm command, giving `helm upgrade requires 2 arguments`.

2. **Unresolved Argo template expression**: when using `zaino-tag` instead of `ref`, the `build-image` step is skipped but its output template `{{steps.build-image.outputs.parameters.image}}` is still passed as the `image` input to `helm-install`. The literal `{{...}}` string is non-empty, so the `if [ -n "$BUILT_IMAGE" ]` check enters the wrong branch. The curly braces then confuse Helm's `--set` parser (which treats `{` and `}` as list syntax), producing `key "}" has no value`. Fixed with a `case` guard that clears `BUILT_IMAGE` if it contains `{{`.

3. **Buildkit lock contention**: submitting two workflows simultaneously caused the second buildkit pod to fail acquiring the lock. Solved by using `zaino-tag` (pre-built image) instead of `ref` for subsequent deploys after the first build.

## Test deployments running

Both deployed successfully against zebra 5.2.0 with PR#1263 (`8f4c234`):

- **preview-1263-8f4c234-2g**: `sync_write_batch_size=2`, running, 0 restarts, metrics emitting
- **preview-1263-8f4c234-8g**: `sync_write_batch_size=8`, running, 1 restart (early), metrics emitting

Metrics confirmed reachable on pod IP:9998. Note: the zaino service template in zcash-stack still doesn't expose `metricsPort` — it's a pre-existing gap, only the gRPC port 8137 is in the Service spec.
