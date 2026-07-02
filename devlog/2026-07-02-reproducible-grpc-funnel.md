# 2026-07-02 — Reproducible public gRPC egress (`expose-public: true`)

Follow-up to [2026-07-01](./2026-07-01-rc6-ephemeral-mode-deploy.md), which got a
one-off public gRPC-over-TLS endpoint working by hand (Funnel TCP passthrough +
nginx). Today: turn that hand-built pod into a reproducible, parametrised thing.

## Decision: standalone component, NOT baked into the zcash-stack chart

The instinct was "bake it into the chart." Rejected, for three reasons:

1. **A pure-chart solution is impossible.** A helm chart renders static
   manifests, but minting the Tailscale authkey is a live API call (OAuth →
   `/api/v2/tailnet/-/keys`). The workflow is always in the loop regardless, so
   the manifests may as well live somewhere clean the workflow drives.
2. **zcash-stack is the shared production app chart.** Bolting an experimental,
   public + unauthenticated egress path into it adds surface area for every
   consumer and locks it to `zaino.*`.
3. **The pattern is service-agnostic** — "TLS-terminating gRPC funnel for any
   h2c backend." `grpc_pass` to any host:port. Undersold as `zaino.publicFunnel`.

⇒ New standalone helm chart `platform/grpc-funnel/`, driven by a
`deploy-ephemeral` param `expose-public: true`.

## What was built

- **`platform/grpc-funnel/chart/`** — Deployment (tailscale + certfetch + nginx),
  serve/nginx ConfigMaps, authkey Secret, state PVC. Values:
  `hostname`, `tailnet`, `backend`, `authkey.{value,existingSecret}`,
  `persistence.*`, `allowFunnel`. `helm template` output matches the known-good
  live rc6 config byte-for-byte on `serve.json` and `nginx.conf`.
- **`deploy-ephemeral`** gained `expose-public`, `public-hostname` (defaults to
  namespace), `tailnet`, `authkey-expiry-seconds`, `chart-ref`. New
  `expose-public` step: reads `tailscale/operator-oauth` via the k8s API (the
  workflow SA already has cluster-wide secret read — no new RBAC), OAuth →
  access token → mints a tagged (`tag:k8s`) reusable non-ephemeral authkey →
  `helm upgrade --install <release>-funnel` from this repo's chart. `report`
  prints the public URL.
- **`cleanup-ephemeral`** restructured into steps: best-effort **device-reap**
  (delete the Tailscale node by `hostname == funnel-host` AND `tag:k8s`) → the
  existing namespace delete.

## Key design choices

- **Durability via PVC-backed tailscale state** (was the historical pain point:
  `mem:` state → restart re-registers as `<host>-N` → cert mismatch). Persistent
  state keeps the node identity *and* the cached cert across restarts. RWO
  `local-path`, single replica, `strategy: Recreate`.
- **Non-ephemeral node ⇒ must reap on teardown.** Durability requires persisted
  identity, which means the node no longer auto-expires. So cleanup reaps it;
  otherwise a stale device forces a `-N` suffix next time. Unique per-deploy
  hostname (defaults to namespace, already carries the commit hash) keeps
  collisions away in the first place.
- **`chart-ref` defaults to `main`** — the production ApplicationSet
  (`clusters/production/appset.yaml`) syncs from `main`, so the chart clone
  tracks the same source of truth; override to test from a branch.
- **Non-ephemeral, reusable, `tag:k8s` authkey**, 7-day expiry. `tag:k8s`
  already carries the `funnel` nodeAttr in nix-infra/tailscale/policy.json.
  Authkey never echoed (no `set -x`).

## Rollout note

Because the WorkflowTemplates are ArgoCD-synced from `main` **and** the funnel
chart is cloned from `main` at deploy time, the whole feature goes live only
once this lands on `main`. Nothing is applied imperatively.

## Open / caveats

- Public Funnel is **unauthenticated** — anyone with the URL hits the backend.
  For time-boxed test exposure only.
- Authkey is passed via `--set-string authkey.value` → it lands in the helm
  release Secret (namespace-scoped). Acceptable for ephemeral namespaces; a
  future tightening could create the Secret out-of-band and use `existingSecret`.
- Not yet exercised end-to-end through the workflow (built + `helm template`
  validated; the live rc6 hand-built funnel is the empirical proof of the design).
