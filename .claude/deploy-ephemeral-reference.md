# deploy-ephemeral — Reference

`deploy-ephemeral` is the **primary way to spin up zaino+zebra test deployments** in
zingo-infra. It creates an isolated namespace, clones golden snapshots, optionally
builds zaino from source, helm-installs zcash-stack, and can expose the gRPC publicly.

**File:** `platform/argo-workflows/workflows/deploy-ephemeral.yaml`
**Namespace:** runs in `argo`; target namespace is created by the workflow itself.
**Requires:** kubeconfig context `zingo-infra`.

## Invocation

```bash
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=<ns> [-p ref=<commit> | -p zaino-tag=<tag>] [other params...]
```

## Two modes

1. **From git ref** (builds image): `-p ref=<full-40-char-commit-hash>`
   - BuildKit clones the repo and builds with `cargo-features`
   - Image tag auto-derived from sanitized ref + features suffix
   - Use `force-build=true` to rebuild even if image exists on Docker Hub
2. **From pre-built tag** (skips build): `-p zaino-tag=0.5.0-rc.7-no-tls-with-prometheus`
   - Built image takes precedence if both `ref` and `zaino-tag` are given

## Namespace naming conventions

| Scenario | Pattern | Example |
|----------|---------|---------|
| PR testing | `pr-<number>-<shorthash>` | `pr-1294-d03cde0d` |
| RC tag testing | `rc<N>-<shorthash>` | `rc7-29e8d4c` |
| RC + qualifier | `rc<N>-<qualifier>-<shorthash>` | `rc7-ephemeral-29e8d4c` |
| Named test | `<purpose>-<shorthash>` | `bisect-1112-a4f2c01` |
| Automated (sensor) | `pr-<number>` | `pr-1294` |

Rules:
- Always include short commit hash for traceability
- No `v` prefix on tags/namespaces
- Must be DNS-1123 compliant (lowercase, alphanumeric + hyphens, max 63 chars)

## All parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `namespace` | (required) | Target namespace |
| `network` | `mainnet` | `mainnet` or `testnet` |
| `ref` | `""` | Git ref to build from (full 40-char hash preferred) |
| `zaino-tag` | `""` | Pre-built image tag (skips build) |
| `cargo-features` | `no_tls_with_prometheus` | Cargo features for build |
| `registry` | `zingodevops/zaino` | Docker Hub image registry |
| `zebra-tag` | `""` | Override zebra image version |
| `zebra-snapshot` | (auto from golden) | Override zebra snapshot name |
| `zaino-snapshot` | (auto from golden) | Override zaino snapshot name |
| `use-zaino-cache` | `false` | Restore zaino DB from golden snapshot |
| `metrics` | `true` | Enable metrics port; set `false` for old refs without prometheus |
| `force-build` | `false` | Rebuild image even if it exists |
| `release-name` | `zaino` | Helm release name |
| `zaino-env` | `""` | Extra env vars: `KEY1=VAL1,KEY2=VAL2` |
| `tailscale` | `false` | Expose on tailnet (private) |
| `expose-public` | `false` | Public gRPC-over-TLS via Funnel+nginx (UNAUTHENTICATED) |
| `public-hostname` | `""` (defaults to namespace) | DNS name for public endpoint |
| `tailnet` | `vaquita-altair.ts.net` | Tailnet domain |
| `authkey-expiry-seconds` | `604800` (7 days) | Tailscale authkey TTL |
| `chart-ref` | `main` | Branch of devops repo for grpc-funnel chart |

## Common recipes

```bash
# Deploy an RC tag with public endpoint + ephemeral mode
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=rc7-ephemeral-29e8d4c \
  -p ref=29e8d4ca262e78955ec807bdbc69e62b40a5912f \
  -p use-zaino-cache=false \
  -p zaino-env=ZAINO_EPHEMERAL_FINALISED_STATE=true \
  -p tailscale=true -p expose-public=true

# Deploy from a pre-built tag, private
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=test-rc1-abc1234 \
  -p zaino-tag=0.5.0-rc.7-no-tls-with-prometheus

# Deploy older ref without metrics support
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=test-old-def5678 \
  -p zaino-tag=0.3.1-no-tls -p metrics=false

# Testnet
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=testnet-abc1234 -p network=testnet -p ref=<hash>
```

## Monitoring & cleanup

```bash
# Watch workflow
argo watch -n argo <workflow-name>
argo logs -n argo <workflow-name> --follow

# Monitor sync after deploy
~/.local/share/zaino/benchmarks/sync-speed-monitor.sh <namespace> 60

# Cleanup (deletes namespace + snapshots + reaps tailscale device)
argo submit --from workflowtemplate/cleanup-ephemeral -n argo \
  -p namespace=<namespace>
```

## Endpoints after deploy

- **gRPC:** `zaino.<ns>.svc:8137` (cluster-internal, plaintext h2c)
- **Zebra RPC:** `zebra.<ns>.svc:8232`
- **Metrics:** port 9998 (`/metrics`) when metrics=true
- **Public:** `<hostname>.<tailnet>:443` (standard gRPC-over-TLS, when expose-public=true)

## GitHub automation (Argo Events sensor)

Sensor at `platform/argo-workflows/events/sensor.yaml` automates PR deploys:
- **"deploy" label added** → triggers `serve-zaino` (namespace `pr-<number>`)
- **Push to labeled PR** → triggers `update-zaino` (hot-swap image)
- **Label removed / PR closed** → triggers `cleanup-ephemeral`

EventSource: GitHub App webhook on `zingolabs/zaino` pull_request events.
Status: EventSource URL is FIXME (not yet wired to public ingress).

## Related workflows

| Template | Purpose |
|----------|---------|
| `build-zaino` | BuildKit image build (called by deploy-ephemeral) |
| `serve-zaino` | Lighter PR testing (zaino-only against golden zebra) |
| `update-zaino` | Hot-swap zaino image in existing namespace |
| `cleanup-ephemeral` | Tear down namespace + reap tailscale device |
| `snapshot-golden` | Create golden snapshots from production |

## Caveats & lessons learned

1. **Full 40-char commit hashes** — BuildKit needs them for remote clone; short hashes fail
2. **IFS leak in zaino-env parsing** — was fixed (commit `492491d`); env vars use comma-separated KEY=VALUE
3. **Unresolved Argo template expressions** — when `build-image` step is skipped, `{{steps.build-image.outputs...}}` returns literal `{{...}}`; helm-install guards with a `case` check
4. **Tailscale `--set-string` not `--set-json`** — annotations must be strings; `--set-json` fails due to unquoted expansion
5. **Non-ephemeral tailscale nodes** — `expose-public` uses persistent state (PVC) for durability, but nodes must be reaped on cleanup or they block hostname reuse
6. **OOMKill corrupts zaino DB** — if zaino is OOMKilled mid-write, finalised-state DB is permanently corrupted; wipe `data-zaino-0` PVC to recover
7. **Metrics param for old refs** — refs before `no_tls_with_prometheus` don't have metrics; pass `metrics=false`
8. **Golden snapshot resolution** — auto-resolves latest `zebra-*` / `data-zaino-*` VolumeSnapshot from `golden-<network>` namespace; override with explicit params if needed
9. **Helm `--wait` and readiness** — zaino's TCP readiness probe blocks until sync starts; `--wait=false` used in deploy to avoid timeout
