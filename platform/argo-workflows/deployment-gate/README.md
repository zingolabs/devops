# Deployment gate (cluster side)

The **cluster half** of the zaino release pipeline's deployment gate. The GitHub
half lives in `zingolabs/zaino` (`rc-gate` creates a GitHub Deployment in the
`deployment` environment on each RC cut; `deployment-advance.yml` fast-forwards
`release-ready` when a `deployment_status: success` comes back).

See `zingolabs/zaino` → `docs/decision_records/release/implementation.md`
§ "The deployment-gate bridge".

## Design: cluster-driven, all outbound

No inbound webhook, no public endpoint, no runner joining the tailnet. The
cluster is a self-contained operator that **monitors GitHub and posts back**:

```
rc-gate creates GitHub Deployment (env: deployment) for the rc commit
   └─ deployment-gate-poller (CronWorkflow, every 2 min)
        · lists Deployments with no status yet
        · TRIVIAL (connection test): posts deployment_status: success
        · REAL (later): submits the deployment-gate WorkflowTemplate
             (serve-zaino warm-start → bench-zaino / manual sign-off),
             which posts success|failure itself
   └─ deployment_status: success  →  deployment-advance.yml advances release-ready
```

A Deployment's own status is the dedup state — once claimed (any status) the
poller skips it. Auth is all outbound to `api.github.com` as the release GitHub
App. This handles **long** soaks naturally (the cluster owns the run) and needs
no public exposure.

## Files

| file | what |
|------|------|
| `poller.yaml` | `deployment-gate-poller` CronWorkflow — the monitor (trivial pass for now) |
| `workflow.yaml` | `deployment-gate` WorkflowTemplate — the real validation the poller will submit once the connection is proven |
| `setup-secrets.sh` | creates the two App secrets in namespace `argo` (run it yourself — it references the key) |
| `kustomization.yaml` | deploys `poller.yaml` (the app def is `platform/defs/deployment-gate.yaml`) |

## Setup (before it works)

1. **App with Deployments R/W.** The release App (sandbox: id `4655069` on
   `nachog00/zaino-pipeline-sandbox`; prod: the org App) needs
   **Repository → Deployments: Read & Write** to list Deployments + post
   statuses. Add it if missing.
2. **Secrets** (namespace `argo`): run `setup-secrets.sh`:
   ```
   APP_ID=4655069 INSTALLATION_ID=<id> PEM=/path/to/app.pem ./setup-secrets.sh
   ```
   Creates `github-app-meta` (appID, installationID) and `github-app`
   (privateKey).
3. **Point at the repo.** `poller.yaml` defaults `repo` to the sandbox for the
   connection test; set it to `zingolabs/zaino` for production.

## Depth is a dial (the real validation, later)

`workflow.yaml` warm-starts from the golden snapshot (`serve-zaino
use-cache=true`) to validate at the **tip** in minutes–hours (wallet-sync
fixtures, tx sends, light-RPC), or fresh-syncs a full index (days). Set
`manual-approval=true` for a human `suspend`/`resume` sign-off. It posts its own
`deployment_status`. Swap the poller's trivial `POST success` for an
`argo submit --from workflowtemplate/deployment-gate` when ready.

## Not yet cluster-validated

The poller's JWT mint + GitHub API calls need a real run to confirm. Test the
GitHub reaction independently via `zingolabs/zaino` →
`tools/scripts/mark-deployment.sh <repo> <rc-sha> success`.
