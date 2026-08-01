# zingo-mobile "UI bug" → Signal notifications

**Date:** 2026-08-01
**Status:** Approved design, pending implementation plan

## Goal

When a "UI bug" issue is flagged on GitHub `zingolabs/zingo-mobile`, an automated
issue-bot posts a message to a private Signal group. The Signal group's sender is a
deliberately anonymous number (temporary, paid for with ZEC) that must stay isolated
from the existing monitoring Signal identity.

## Context / what we reuse

The cluster already runs two patterns this composes from:

- **Sending half** — `platform/signal-bridge/` (`monitoring` ns): a
  `bbernhard/signal-cli-rest-api` pod holding the registered *monitoring* Signal
  account, REST API on `:8080`, credentials restored from a SealedSecret by an init
  container. Currently fed by `alertmanager-webhook-signal` (Alertmanager-specific).
- **Trigger half** — `platform/argo-workflows/events/` (`argo` ns): Argo Events
  GitHub EventSource → EventBus (`default`, 3-replica NATS JetStream) → Sensor with
  payload filters → triggers. Currently wired for `zingolabs/zaino` `pull_request`
  events driving deploy workflows.

The new issue-bot is these two patterns re-pointed: a GitHub `issues` EventSource, a
Sensor filtering for the "UI bug" label, and an HTTP trigger that sends to a
**dedicated, isolated** signal-cli pod.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| How is a "UI bug issue" identified? | Label **added post-open**: `action == labeled` + `label.name == "UI bug"`. Fires whenever the label is applied, including to pre-existing issues. |
| Anon account credential isolation | **Dedicated signal-cli pod** — own Deployment, PVC, and SealedSecret. The anon identity never shares a pod or volume with the monitoring number. |
| Notice → send delivery path | **Option A: direct HTTP trigger.** Sensor `http` trigger POSTs straight to signal-cli `/v2/send`. No new bridge service. |
| GitHub App | **Separate app** dedicated to the mobile issue-bot. Cleaner separation from the zaino deploy app. |
| signal-cli pod namespace | **New `signal-issuebot` namespace** — isolates the anon identity from everything else. |
| Event plumbing namespace | **`argo` ns, reusing the existing `default` EventBus.** The webhook/sensor is non-sensitive plumbing; reusing the EventBus avoids standing up a second NATS JetStream cluster for a single notification. |

Rationale on the split: the only genuinely sensitive artifact is the anon Signal
identity, which lives alone in `signal-issuebot`. The EventSource/Sensor, the GitHub
App key, and the webhook secret are non-anonymous plumbing and live in `argo` beside
the existing zaino integration. Cross-namespace send is a plain in-cluster hop:
`http://signal-cli.signal-issuebot.svc.cluster.local:8080`.

## Architecture

```
GitHub: zingolabs/zingo-mobile issue labeled "UI bug"
  │  webhook (GitHub App, separate)
  ▼
EventSource  github-zingo-mobile        (argo ns)
  │
  ▼
EventBus  default                       (argo ns, existing, reused)
  │
  ▼
Sensor  zingo-mobile-ui-bug             (argo ns)
  │  filter: X-Github-Event==issues, body.action==labeled, body.label.name=="UI bug"
  │  http trigger, payload-templated body
  ▼
signal-cli  POST /v2/send              (signal-issuebot ns)
  │  { number: <anon>, recipients: [<group id>], message: <templated> }
  ▼
Signal group
```

## Components

### 1. `platform/signal-issuebot/` — dedicated signal-cli (ns: `signal-issuebot`)

Mirror of `platform/signal-bridge/signal-cli.yaml`, isolated:

- `Namespace` `signal-issuebot`.
- `PersistentVolumeClaim` `signal-cli-config` (`local-path`, 1Gi) — separate volume.
- `Deployment` `signal-cli`, image `bbernhard/signal-cli-rest-api:0.100`, `MODE=json-rpc`,
  `strategy: Recreate`. Init container `restore-credentials` untars creds from the
  SealedSecret onto the PVC on first boot (skips if `accounts.json` present).
- `Service` `signal-cli` → `:8080`.
- `SealedSecret` `signal-cli-credentials` (`data.tar.gz`) — the **anon** account only.
  Produced operationally (see prereqs); the sealed output is committed.
- `kustomization.yaml` with `namespace: signal-issuebot`.

Resources match the existing pod (requests `cpu 10m` / `mem 256Mi`, limit `mem 512Mi`).

### 2. `platform/signal-issuebot/events/` — EventSource + Sensor (deploy into `argo` ns)

Kept in its own kustomize dir (separate concern from the zaino deploy sensor) but the
resources target the `argo` namespace and the existing `default` EventBus. **Does not
declare an EventBus** — it reuses the one already in `argo`.

**EventSource `github-zingo-mobile`:**
- `github` source, repo `zingolabs/zingo-mobile`, `events: [issues]`.
- Webhook endpoint `/webhook/zingo-mobile`, port `12000`, `contentType: json`,
  `url: https://<public-funnel-url>/webhook/zingo-mobile` (set at implementation).
- `githubApp` auth referencing the **separate** app secret (`github-app-mobile`).
- `webhookSecret` referencing `github-webhook-secret-mobile`.

**Sensor `zingo-mobile-ui-bug`:**
- One dependency `ui-bug-labeled` on `github-zingo-mobile` / event `zingo-mobile` with
  data filters:
  - `headers.X-Github-Event == issues`
  - `body.action == labeled`
  - `body.label.name == "UI bug"`  *(exact string — verify casing against the repo's
    actual label during implementation)*
- One `http` trigger:
  - `url: http://signal-cli.signal-issuebot.svc.cluster.local:8080/v2/send`
  - `method: POST`
  - Static payload fields: `number` = anon number, `recipients` = `[<group id>]`.
  - Templated payload field `message`, built from the event body (see template).
  - `retryStrategy`: steps 3, duration 30s (consistent with existing sensor).
- Service account: minimal SA in `argo` (the http trigger needs no workflow-submit
  RBAC, so it does not reuse `events-webhook-sa`'s workflow permissions; a dedicated
  no-privilege SA is created, or the namespace default is used).

### 3. `platform/defs/signal-issuebot.yaml` — ArgoCD app registration

Per the app-registration convention (`platform/defs/*.yaml`). One app for
`platform/signal-issuebot` (the pod, ns `signal-issuebot`) and one for
`platform/signal-issuebot/events` (targets `argo`). Two defs if the source paths need
distinct destination namespaces.

## Message template

Built by the Sensor http trigger from the `issues` webhook payload:

```
🐛 UI bug · zingo-mobile #{{ body.issue.number }}
{{ body.issue.title }}
opened by @{{ body.issue.user.login }} · labeled by @{{ body.sender.login }}
{{ body.issue.html_url }}
```

Rendered example:

> 🐛 UI bug · zingo-mobile #1234
> Login screen crops on small screens
> opened by @alice · labeled by @bob
> https://github.com/zingolabs/zingo-mobile/issues/1234

## signal-cli send contract

`POST /v2/send` body:

```json
{
  "message": "<templated>",
  "number": "<anon sender number, E.164>",
  "recipients": ["<internal group id>"]
}
```

The group id is the internal Signal group identifier from `signal-cli listGroups`
(not the human group name).

## Operational prerequisites (run by the user; secret-touching steps scripted)

Per the no-secrets-in-agent-tools policy, all steps that touch the private key /
account credentials are delivered as a script for the user to run; the agent never
reads or pipes the secret material.

1. **Register the anon number** into a signal-cli instance, then capture the account
   data as a SealedSecret `signal-cli-credentials` in `signal-issuebot` (same
   `tar czf … | kubeseal` flow documented in `platform/signal-bridge/signal-cli.yaml`).
2. **Create the separate GitHub App** on `zingolabs/zingo-mobile`:
   - Permissions: Repository → Issues: **Read**.
   - Subscribe to events: **Issues**.
   - Install on `zingo-mobile`; note App ID + Installation ID; generate a private key.
   - Create secrets in `argo`: `github-app-mobile` (`privateKey`) and
     `github-webhook-secret-mobile` (`secret` = `openssl rand -hex 20`).
3. **Publish the webhook URL** — expose the EventSource service via Tailscale Funnel /
   Ingress and set the EventSource `url`.
4. **Fetch the group id** via `signal-cli listGroups`; put it in the Sensor trigger's
   `recipients` (non-sensitive; committed).
5. **Confirm the exact label string** on `zingo-mobile` (casing/spacing) and align the
   Sensor filter.

## Error handling & edge cases

- **Duplicate fires:** `labeled` fires each time the label is (re)applied; remove+re-add
  sends twice. Acceptable for v1; note it. A dedupe layer is out of scope.
- **Old issues:** applying "UI bug" to a historical issue will notify — matches intent.
- **Delivery failure:** the sensor `http` trigger retries (3× / 30s). Beyond that the
  event is dropped; there is no persistent queue in option A. If durable delivery /
  audit history becomes a requirement, migrate to option B (Sensor → Argo Workflow →
  curl), which gives per-run logs and retries. Recorded as the upgrade path.
- **Pod restart:** creds persist on the PVC; init container is idempotent.

## Testing / verification

- **Filter unit check:** replay a captured `issues/labeled` payload through the sensor
  filter logic (or a dry Argo Events test) to confirm only `"UI bug"` labels match.
- **Send check:** `curl` the signal-cli `/v2/send` from within the cluster with a test
  message to confirm the anon account reaches the group.
- **End-to-end:** label a throwaway issue on `zingo-mobile` "UI bug"; confirm the
  message lands in the Signal group with correct title/number/link.

## Out of scope (YAGNI)

- Enriching messages with issue body/labels via the GitHub API (option B territory).
- Dedupe / idempotency store.
- Reactions or two-way interaction from Signal back to GitHub.
- Notifying on any non-"UI bug" issue activity.

## Non-obvious follow-ups

- Remind: append a devlog entry capturing the reasoning (patterns reused, isolation
  split, option A vs B upgrade path) once implemented.
