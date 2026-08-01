# zingo-mobile "UI bug" → Signal Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a `zingolabs/zingo-mobile` issue is labeled "UI bug", an Argo Events Sensor posts a formatted message to a private Signal group via a dedicated, isolated signal-cli pod.

**Architecture:** Compose two existing cluster patterns. A dedicated `signal-cli-rest-api` pod in a new `signal-issuebot` namespace holds the anonymous sender identity (own PVC + SealedSecret). A GitHub `issues` EventSource + Sensor in the `argo` namespace (reusing the existing `default` EventBus) filters for the "UI bug" label and fires an `http` trigger straight to that pod's `/v2/send`.

**Tech Stack:** Kubernetes, Kustomize, ArgoCD ApplicationSet (path/def-based), Argo Events (EventSource/Sensor/EventBus), `bbernhard/signal-cli-rest-api`, SealedSecrets, GitHub App webhooks.

**Spec:** `docs/superpowers/specs/2026-08-01-zingo-mobile-ui-bug-signal-notifs-design.md`

---

## Conventions in this repo (read before starting)

- **App registration:** `clusters/production/appset.yaml` (and `clusters/local`) generate one ArgoCD Application per `platform/defs/*.yaml`. Each def is `{name, namespace, sourcePath}`. `sourcePath` is a Kustomize dir; `namespace` is the ArgoCD destination namespace; `CreateNamespace=true` + `selfHeal`/`prune` are already set globally. A def maps one sourcePath → one destination namespace, so components landing in different namespaces need **separate defs**.
- **No imperative kubectl for managed resources** — everything ships via git → ArgoCD sync. `kubectl` is only for one-off ops (registration, listGroups, sealing) that produce committed artifacts.
- **Secrets policy:** the agent never reads/pipes private keys or account credentials. All credential-touching steps are delivered as a script the **user runs**; only the resulting SealedSecret / non-sensitive output is committed.
- **Commits:** concise imperative, no co-author/generated footers. GPG signing may fail in-sandbox (no secret key); commit unsigned and let the user re-sign if desired.

## File Structure

**Create:**
- `platform/signal-issuebot/kustomization.yaml` — pod app (ns `signal-issuebot`)
- `platform/signal-issuebot/signal-cli.yaml` — PVC + Deployment + Service (dedicated signal-cli)
- `platform/signal-issuebot/sealed-signal-credentials.yaml` — anon account creds (produced by user script)
- `platform/signal-issuebot/events/kustomization.yaml` — events app (ns `argo`)
- `platform/signal-issuebot/events/eventsource.yaml` — GitHub `issues` EventSource for zingo-mobile
- `platform/signal-issuebot/events/sensor.yaml` — "UI bug" filter + http trigger
- `platform/defs/signal-issuebot.yaml` — ArgoCD app for the pod (ns `signal-issuebot`)
- `platform/defs/signal-issuebot-events.yaml` — ArgoCD app for the events (ns `argo`)
- `scripts/register-issuebot-signal.sh` — user-run: register anon number, seal creds
- `scripts/create-mobile-github-app-secrets.sh` — user-run: create GitHub App + webhook secrets in `argo`

**Reuse (no change):** `platform/argo-workflows/events/eventbus.yaml` (the `default` EventBus in `argo`).

**Note on secrets before first sync:** ArgoCD `selfHeal`+`prune` are on. Commit the events app def **after** the `github-app-mobile` / `github-webhook-secret-mobile` secrets and the webhook URL exist, and commit the pod app def with the SealedSecret in place, so the first sync doesn't crashloop on missing secrets. Task ordering below enforces this.

---

## Task 1: Dedicated signal-cli pod manifests

**Files:**
- Create: `platform/signal-issuebot/signal-cli.yaml`
- Create: `platform/signal-issuebot/kustomization.yaml`

- [ ] **Step 1: Write `platform/signal-issuebot/signal-cli.yaml`**

Dedicated mirror of `platform/signal-bridge/signal-cli.yaml`, isolated PVC/creds. No `namespace:` in metadata (Kustomize sets it).

```yaml
# Dedicated signal-cli-rest-api for the zingo-mobile issue-bot.
# Holds ONLY the anonymous (ZEC-paid) sender identity — isolated from the
# monitoring signal-cli in the `monitoring` namespace.
#
# Credentials are restored to the PVC from a SealedSecret by an init container
# on first boot. Registration + sealing is done out-of-band by
# scripts/register-issuebot-signal.sh (see plan / spec).
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: signal-cli-config
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signal-cli
  labels:
    app: signal-cli
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: signal-cli
  template:
    metadata:
      labels:
        app: signal-cli
    spec:
      initContainers:
        - name: restore-credentials
          image: busybox:1.37
          command: ["sh", "-c"]
          args:
            - |
              if [ -f /data/data/accounts.json ]; then
                echo "Credentials already present, skipping restore"
              else
                echo "Restoring credentials from sealed secret"
                cd /data && tar xzf /credentials/data.tar.gz
              fi
          volumeMounts:
            - name: config
              mountPath: /data
            - name: credentials
              mountPath: /credentials
              readOnly: true
      containers:
        - name: signal-cli
          image: bbernhard/signal-cli-rest-api:0.100
          env:
            - name: MODE
              value: json-rpc
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 10m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /home/.local/share/signal-cli
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: signal-cli-config
        - name: credentials
          secret:
            secretName: signal-cli-credentials
---
apiVersion: v1
kind: Service
metadata:
  name: signal-cli
spec:
  selector:
    app: signal-cli
  ports:
    - name: http
      port: 8080
      targetPort: http
```

- [ ] **Step 2: Write `platform/signal-issuebot/kustomization.yaml`**

Does NOT yet list the sealed secret (created in Task 2) so this task validates standalone.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: signal-issuebot

resources:
  - signal-cli.yaml
```

- [ ] **Step 3: Validate the render**

Run: `kubectl kustomize platform/signal-issuebot`
Expected: renders PVC, Deployment, Service, all with `namespace: signal-issuebot`. No errors.

- [ ] **Step 4: Commit**

```bash
git add platform/signal-issuebot/signal-cli.yaml platform/signal-issuebot/kustomization.yaml
git commit --no-gpg-sign -m "Add dedicated signal-cli pod for zingo-mobile issue-bot"
```

---

## Task 2: Anon account registration + SealedSecret (user-run)

**Files:**
- Create: `scripts/register-issuebot-signal.sh`
- Create (by running the script): `platform/signal-issuebot/sealed-signal-credentials.yaml`
- Modify: `platform/signal-issuebot/kustomization.yaml`

- [ ] **Step 1: Write `scripts/register-issuebot-signal.sh`**

The agent writes this script; the **user runs it** (it touches account credentials). It temporarily runs signal-cli locally (podman, per user tooling preference) to register/verify the anon number, then packages + seals the account data. Assumes the group already exists (it does).

```bash
#!/usr/bin/env bash
# Register the anonymous issue-bot Signal number and produce a SealedSecret.
# RUN THIS YOURSELF — it handles account credentials the agent must not touch.
#
# Prereq: podman, kubeseal, kubectl (zingo-infra context), the anon number's SMS/voice
# access for the verification code.
set -euo pipefail

ANON_NUMBER="${ANON_NUMBER:?export ANON_NUMBER=+<E.164 anon number>}"
DATA_DIR="$(mktemp -d)"
IMAGE="bbernhard/signal-cli-rest-api:0.100"

echo ">> Starting a throwaway signal-cli to register ${ANON_NUMBER}"
podman run -d --name issuebot-signal-reg \
  -e MODE=json-rpc \
  -v "${DATA_DIR}:/home/.local/share/signal-cli" \
  -p 8099:8080 "${IMAGE}"

echo ">> Waiting for API..."; sleep 8

# Register (CAPTCHA may be required — visit the printed link if so).
echo ">> Requesting registration for ${ANON_NUMBER}"
curl -fsS -X POST "http://localhost:8099/v1/register/${ANON_NUMBER}" || {
  echo "Registration may need a captcha token. See:"
  echo "  https://github.com/bbernhard/signal-cli-rest-api/blob/master/doc/CAPTCHA.md"
  echo "Then re-run with a captcha: curl -X POST 'http://localhost:8099/v1/register/${ANON_NUMBER}' -H 'Content-Type: application/json' -d '{\"captcha\":\"<token>\"}'"
}

read -rp ">> Enter the SMS verification code you received: " CODE
curl -fsS -X POST "http://localhost:8099/v1/register/${ANON_NUMBER}/verify/${CODE}"

echo ">> Confirming the account is registered"
curl -fsS "http://localhost:8099/v1/accounts" | grep -q "${ANON_NUMBER}" \
  && echo "OK: ${ANON_NUMBER} registered"

echo ">> Listing groups (copy the internal group id for the Sensor recipients)"
curl -fsS "http://localhost:8099/v1/groups/${ANON_NUMBER}" | tee "${DATA_DIR}/../groups.json"

echo ">> Packaging + sealing credentials"
podman stop issuebot-signal-reg
tar czf "${DATA_DIR}/../data.tar.gz" -C "${DATA_DIR}" data/

kubectl create secret generic signal-cli-credentials -n signal-issuebot \
  --from-file=data.tar.gz="${DATA_DIR}/../data.tar.gz" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system -o yaml \
  > platform/signal-issuebot/sealed-signal-credentials.yaml

echo ">> Wrote platform/signal-issuebot/sealed-signal-credentials.yaml"
echo ">> Cleanup: podman rm issuebot-signal-reg ; rm -rf ${DATA_DIR%/*}"
echo ">> Record the group id from groups.json for Task 5."
```

- [ ] **Step 2: User runs the script**

Ask the user to run:
```bash
ANON_NUMBER=+<anon> bash scripts/register-issuebot-signal.sh
```
Expected: `platform/signal-issuebot/sealed-signal-credentials.yaml` created; the anon number's **internal group id** captured for Task 5.

- [ ] **Step 3: Add the SealedSecret to the kustomization**

Edit `platform/signal-issuebot/kustomization.yaml` — append under `resources:`:
```yaml
  - sealed-signal-credentials.yaml
```

- [ ] **Step 4: Validate the render**

Run: `kubectl kustomize platform/signal-issuebot`
Expected: now also renders a `SealedSecret` named `signal-cli-credentials` in `namespace: signal-issuebot`.

- [ ] **Step 5: Commit**

```bash
git add scripts/register-issuebot-signal.sh platform/signal-issuebot/sealed-signal-credentials.yaml platform/signal-issuebot/kustomization.yaml
git commit --no-gpg-sign -m "Add issuebot Signal registration script and sealed credentials"
```

---

## Task 3: GitHub App secrets for zingo-mobile (user-run)

**Files:**
- Create: `scripts/create-mobile-github-app-secrets.sh`

- [ ] **Step 1: Write `scripts/create-mobile-github-app-secrets.sh`**

Agent writes; **user runs** (handles the App private key). Creates the two secrets the EventSource references, in `argo`.

```bash
#!/usr/bin/env bash
# Create the GitHub App + webhook secrets for the zingo-mobile issue-bot EventSource.
# RUN THIS YOURSELF — it handles the GitHub App private key the agent must not touch.
#
# Prereq: a SEPARATE GitHub App created + installed on zingolabs/zingo-mobile with:
#   Permissions: Repository -> Issues: Read
#   Subscribe to events: Issues
# You have: the App private key .pem, the App ID, the Installation ID.
set -euo pipefail

PEM_PATH="${PEM_PATH:?export PEM_PATH=/path/to/zingo-mobile-issuebot.private-key.pem}"

kubectl create secret generic github-app-mobile -n argo \
  --from-file=privateKey="${PEM_PATH}"

kubectl create secret generic github-webhook-secret-mobile -n argo \
  --from-literal=secret="$(openssl rand -hex 20)"

echo ">> Created github-app-mobile and github-webhook-secret-mobile in namespace argo"
echo ">> Note the webhook secret value if you need it in the GitHub App config:"
kubectl get secret github-webhook-secret-mobile -n argo -o jsonpath='{.data.secret}' | base64 -d; echo
```

- [ ] **Step 2: User runs the script**

Ask the user to:
1. Create the separate GitHub App (Issues: Read, subscribe to Issues) and install it on `zingolabs/zingo-mobile`.
2. Run:
```bash
PEM_PATH=/path/to/key.pem bash scripts/create-mobile-github-app-secrets.sh
```
Record the **App ID** and **Installation ID** for Task 4.

- [ ] **Step 3: Commit the script**

```bash
git add scripts/create-mobile-github-app-secrets.sh
git commit --no-gpg-sign -m "Add script to provision zingo-mobile GitHub App secrets"
```

---

## Task 4: EventSource for zingo-mobile issues

**Files:**
- Create: `platform/signal-issuebot/events/eventsource.yaml`

- [ ] **Step 1: Write `platform/signal-issuebot/events/eventsource.yaml`**

Modeled on `platform/argo-workflows/events/eventsource.yaml` but for `issues`. Replace `<APP_ID>`, `<INSTALLATION_ID>` (from Task 3) and `<PUBLIC_URL>` (Task 6) at fill-in.

```yaml
# GitHub EventSource for zingolabs/zingo-mobile issue events.
# Separate GitHub App from the zaino integration (see spec).
# Secrets github-app-mobile / github-webhook-secret-mobile are created by
# scripts/create-mobile-github-app-secrets.sh.
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: github-zingo-mobile
  namespace: argo
spec:
  service:
    ports:
      - name: webhook
        port: 13000
        targetPort: 13000
  github:
    zingo-mobile:
      repositories:
        - owner: zingolabs
          names:
            - zingo-mobile
      webhook:
        endpoint: /webhook/zingo-mobile
        port: "13000"
        method: POST
        # FIXME(Task 6): public URL where GitHub reaches this endpoint (Tailscale Funnel/Ingress).
        url: https://FIXME-PUBLIC-URL/webhook/zingo-mobile
      events:
        - issues
      githubApp:
        appID: 0            # FIXME(Task 3): zingo-mobile issue-bot App ID
        installationID: 0   # FIXME(Task 3): installation ID on zingolabs/zingo-mobile
        privateKey:
          name: github-app-mobile
          key: privateKey
      webhookSecret:
        name: github-webhook-secret-mobile
        key: secret
      insecure: false
      active: true
      contentType: json
```

- [ ] **Step 2: Validate YAML parses**

Run: `kubectl kustomize platform/signal-issuebot/events 2>&1 || echo "kustomization added in Task 5"`
Expected: at this point the kustomization doesn't exist yet; confirm the file itself parses:
Run: `kubectl apply --dry-run=client -f platform/signal-issuebot/events/eventsource.yaml`
Expected: `eventsource.argoproj.io/github-zingo-mobile created (dry run)` (or a validation-only message if the CRD schema isn't checked client-side).

- [ ] **Step 3: Commit**

```bash
git add platform/signal-issuebot/events/eventsource.yaml
git commit --no-gpg-sign -m "Add zingo-mobile issues EventSource"
```

---

## Task 5: Sensor — "UI bug" filter + Signal http trigger

**Files:**
- Create: `platform/signal-issuebot/events/sensor.yaml`
- Create: `platform/signal-issuebot/events/kustomization.yaml`

- [ ] **Step 1: Write `platform/signal-issuebot/events/sensor.yaml`**

Filters `issues`/`labeled`/`"UI bug"`; one `http` trigger builds the `/v2/send` JSON body via `payload` parameters. `<ANON_NUMBER>` and `<GROUP_ID>` come from Task 2. **Verify the exact label string** against the repo.

```yaml
# Sensor: notify a Signal group when a zingo-mobile issue is labeled "UI bug".
#
# GitHub `issues` webhook payload paths used:
#   headers.X-Github-Event        -> "issues"
#   body.action                   -> "labeled"
#   body.label.name               -> the label just added
#   body.issue.number/title/html_url/user.login
#   body.sender.login             -> who applied the label
#
# The http trigger POSTs to the dedicated signal-cli /v2/send:
#   { "number": <anon>, "recipients": [<group id>], "message": <templated> }
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: zingo-mobile-ui-bug
  namespace: argo
spec:
  template:
    serviceAccountName: zingo-mobile-issuebot-sa
  dependencies:
    - name: ui-bug-labeled
      eventSourceName: github-zingo-mobile
      eventName: zingo-mobile
      filters:
        data:
          - path: headers.X-Github-Event
            type: string
            value:
              - issues
          - path: body.action
            type: string
            value:
              - labeled
          - path: body.label.name
            type: string
            value:
              - "UI bug"   # FIXME: confirm exact casing/spacing on zingo-mobile
  triggers:
    - template:
        name: signal-notify
        conditions: ui-bug-labeled
        http:
          url: http://signal-cli.signal-issuebot.svc.cluster.local:8080/v2/send
          method: POST
          headers:
            Content-Type: application/json
          payload:
            # sender (anon number) — static
            - src:
                dependencyName: ui-bug-labeled
                value: "<ANON_NUMBER>"   # FIXME(Task 2): +E.164 anon number
              dest: number
            # recipient group id — static, single-element array
            - src:
                dependencyName: ui-bug-labeled
                value: "<GROUP_ID>"      # FIXME(Task 2): internal group id from listGroups
              dest: recipients.0
            # message — templated from the issue payload
            - src:
                dependencyName: ui-bug-labeled
                dataTemplate: "🐛 UI bug · zingo-mobile #{{ .Input.body.issue.number }}\n{{ .Input.body.issue.title }}\nopened by @{{ .Input.body.issue.user.login }} · labeled by @{{ .Input.body.sender.login }}\n{{ .Input.body.issue.html_url }}"
              dest: message
      retryStrategy:
        steps: 3
        duration: 30s
```

- [ ] **Step 2: Write `platform/signal-issuebot/events/kustomization.yaml`**

Includes the EventSource, Sensor, and a minimal ServiceAccount (below). Destination ns is `argo` (set via the app def, and resources already carry `namespace: argo`).

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - serviceaccount.yaml
  - eventsource.yaml
  - sensor.yaml
```

- [ ] **Step 3: Write the minimal ServiceAccount `platform/signal-issuebot/events/serviceaccount.yaml`**

The http trigger needs no workflow-submit RBAC (unlike the zaino sensor's `events-webhook-sa`), so a bare SA suffices.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: zingo-mobile-issuebot-sa
  namespace: argo
```

Then add it to the kustomization resources list (already listed above as `serviceaccount.yaml`).

- [ ] **Step 4: Validate the render**

Run: `kubectl kustomize platform/signal-issuebot/events`
Expected: renders ServiceAccount, EventSource, Sensor without error.

- [ ] **Step 5: Commit**

```bash
git add platform/signal-issuebot/events/sensor.yaml platform/signal-issuebot/events/serviceaccount.yaml platform/signal-issuebot/events/kustomization.yaml
git commit --no-gpg-sign -m "Add zingo-mobile UI-bug Sensor with Signal http trigger"
```

---

## Task 6: Fill in IDs + public URL, then register ArgoCD apps

**Files:**
- Modify: `platform/signal-issuebot/events/eventsource.yaml`
- Modify: `platform/signal-issuebot/events/sensor.yaml`
- Create: `platform/defs/signal-issuebot.yaml`
- Create: `platform/defs/signal-issuebot-events.yaml`

- [ ] **Step 1: Fill EventSource FIXMEs**

Edit `platform/signal-issuebot/events/eventsource.yaml`: set `appID`, `installationID` (Task 3), and the `url` public host. Determine the public URL by exposing the EventSource service via Tailscale Funnel/Ingress (follow the pattern used for the zaino EventSource; the service is `github-zingo-mobile-eventsource-svc` on port 13000). Example:
```yaml
        url: https://github-zingo-mobile-eventsource-svc.tail-XXXXX.ts.net/webhook/zingo-mobile
```

- [ ] **Step 2: Fill Sensor FIXMEs**

Edit `platform/signal-issuebot/events/sensor.yaml`: replace `<ANON_NUMBER>` and `<GROUP_ID>` with the values from Task 2, and confirm the `"UI bug"` label string.

- [ ] **Step 3: Write `platform/defs/signal-issuebot.yaml`**

```yaml
name: signal-issuebot
namespace: signal-issuebot
sourcePath: platform/signal-issuebot
```

- [ ] **Step 4: Write `platform/defs/signal-issuebot-events.yaml`**

```yaml
name: signal-issuebot-events
namespace: argo
sourcePath: platform/signal-issuebot/events
```

- [ ] **Step 5: Validate both apps render before ArgoCD sees them**

Run: `kubectl kustomize platform/signal-issuebot && echo '---' && kubectl kustomize platform/signal-issuebot/events`
Expected: both render cleanly with all FIXMEs replaced (grep for leftovers):
Run: `grep -rn "FIXME\|<ANON_NUMBER>\|<GROUP_ID>\|FIXME-PUBLIC-URL" platform/signal-issuebot`
Expected: no output.

- [ ] **Step 6: Commit (this is the go-live commit — ArgoCD will sync)**

Only commit the defs once the secrets (Task 2, Task 3) and the SealedSecret are already committed/applied, so the first sync has everything it needs.
```bash
git add platform/signal-issuebot/events/eventsource.yaml platform/signal-issuebot/events/sensor.yaml platform/defs/signal-issuebot.yaml platform/defs/signal-issuebot-events.yaml
git commit --no-gpg-sign -m "Register zingo-mobile issue-bot ArgoCD apps (go-live)"
```

- [ ] **Step 7: Push and confirm ArgoCD sync**

Push the branch/PR per the repo's normal flow (default PR branch is `dev`). After merge to the tracked revision (`main`), confirm ArgoCD created and synced both apps:
```bash
kubectl -n argocd get applications.argoproj.io signal-issuebot signal-issuebot-events
kubectl -n signal-issuebot get pods
kubectl -n argo get eventsource github-zingo-mobile
kubectl -n argo get sensor zingo-mobile-ui-bug
```
Expected: apps `Synced`/`Healthy`; signal-cli pod `Running`; EventSource/Sensor present.

---

## Task 7: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: In-cluster send smoke test**

Confirm the anon account can reach the group directly (isolates the signal-cli half from the webhook half):
```bash
kubectl -n signal-issuebot exec deploy/signal-cli -- \
  curl -fsS -X POST http://localhost:8080/v2/send \
  -H 'Content-Type: application/json' \
  -d '{"number":"<ANON_NUMBER>","recipients":["<GROUP_ID>"],"message":"issue-bot smoke test ✅"}'
```
Expected: HTTP 201 and the message appears in the Signal group.

- [ ] **Step 2: Confirm the GitHub webhook is delivering**

In the GitHub App's Advanced → Recent Deliveries (or repo webhook settings), confirm a green delivery when you label an issue. Also:
```bash
kubectl -n argo logs deploy/github-zingo-mobile-eventsource-svc --tail=50
```
Expected: the EventSource logs the received `issues` event.

- [ ] **Step 3: Full end-to-end**

On a throwaway `zingolabs/zingo-mobile` issue, add the "UI bug" label. Watch the Sensor:
```bash
kubectl -n argo logs -l sensor-name=zingo-mobile-ui-bug --tail=50
```
Expected: Sensor logs the triggered `signal-notify` action; the formatted message (title, #number, author, link) lands in the Signal group.

- [ ] **Step 4: Negative check**

Add a different label (not "UI bug") to an issue.
Expected: no Signal message; Sensor does not trigger (filter rejects).

- [ ] **Step 5: Update the devlog**

Append (never overwrite) a `devlog/2026-08-01-*.md` entry capturing: the two reused patterns, the isolation split (anon identity alone in `signal-issuebot`, plumbing in `argo`), the option-A direct-http choice and the option-B upgrade path, and the "labeled fires on re-add / old issues" caveat.
```bash
git add devlog/2026-08-01-*.md
git commit --no-gpg-sign -m "devlog: zingo-mobile UI-bug Signal notifications"
```

---

## Notes / known caveats (carried from spec)

- **Anon number/group id in git:** they live as literals in the committed Sensor. They're shared with every group member already, so this is low-risk, but if you want them out of git, the upgrade path is option B (Sensor → Argo Workflow → curl, reading them from a Secret).
- **Duplicate fires:** `labeled` fires on every (re)application of the label; remove+re-add double-sends. No dedupe in v1.
- **No durable queue:** option A retries 3×/30s then drops. Move to option B if durable delivery/audit history is needed.
- **Docs maintenance:** this component is independent of `deploy-ephemeral`, so `.claude/deploy-ephemeral-reference.md` is unaffected.
