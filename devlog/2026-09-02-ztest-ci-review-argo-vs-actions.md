# 2026-09-02 — ztest CI review: GitHub Actions-over-tailnet vs event-driven in-cluster

Review session on Eli's ztest CI draft (devops#9 `feat/ztest-infrastructure`) plus its companions
across three other repos. No code changed here; the output is a design note posted as a comment on
devops#9 (issuecomment-5516873401). This entry captures the reasoning so it isn't lost.

## The end goal (inferred — the PRs don't state it)

Make every zaino PR run zaino's **live test suite** against a real cluster. `ztest` is not a unit
runner: it imperatively **manages** a run — creates a per-run namespace, provisions storage +
observability, deploys the system under test, runs the suite, tears it down. That's why the role it
binds (`ztest-remote`, from ztest's `src/resource/impls/policy.rs`) needs namespace
create/patch/delete.

## The pieces are spread across 4 repos

- **devops#9** — cluster RBAC (`ztest-ci` group → `ztest-remote`), zot registry rework, TopoLVM
  default-class flip, `apiServerProxyConfig` on.
- **machines#15** (`feat/arbei`, opened same day) — the node/OS half of the *same* registry+storage
  work: `registries.yaml` mirror (`zot…:5000`→`http://127.0.0.1:30500`, `docker.io`→gcr),
  `nodeport-addresses=127.0.0.1/32` (loopback-only NodePort), `topolvm-node.nix` (thin-pool survives
  reboot). **All model-agnostic infra.**
- **zingolabs/ztest** — its own repo, released 0.1.10 today. The `ztest` CLI/harness
  (`cluster setup`/`cluster check`, `policy.rs`, `ztest-remote`). Not a zaino PR.
- **zaino#1458** (`Add Sync Tests via Ztest`) — the actual live-test payload (`live-tests/sync/`).

**Two keystones do NOT exist yet:** (a) the GitHub Actions workflow that would join the tailnet and
drive ztest — no open PR adds it; the current `trigger-integration-tests.yml` still uses a stored
GitHub App token dispatching to `zcash/integration-tests` (the old secret-based model). (b) the
machines `policy.hujson` `cap/kubernetes` impersonation grant the devops#9 README *quotes* — today
`policy.hujson` only has the deploy-oriented `tag:ci`. So **devops#9 alone is inert** (its binding
maps a group nothing impersonates into).

## Key finding — what `tag:ci` actually is

The devops#9 README casually says zaino CI "joins the tailnet as tag:ci". Investigated the machines
tailnet setup:
- **One** Tailscale OAuth client via **GitHub OIDC workload-identity federation** (no stored
  secret; non-secret `TS_OIDC_CLIENT_ID`/`TS_OIDC_AUDIENCE` vars), federated to
  `repo:zingolabs/machines`, scoped **both** `policy_file` (ACL rewrite) **and** `auth_keys`.
- `tag:ci` = the **machines deploy identity**: owned by `autogroup:admin`, SSH:22 to `tag:k8s-node`,
  lands as the keyless `operator` account for deploy-rs.
- **Insight:** reusing `tag:ci` for zaino tests is both impossible (**OIDC federation is per-repo** —
  a `repo:zingolabs/zaino` token is rejected by the machines client) and dangerous (it'd give zaino
  PR code node-deploy + ACL-write). Model A therefore needs a *new* least-privilege identity:
  `tag:ztest-runner` + a 2nd OIDC client (repo:zaino, `auth_keys` only) + the `cap/kubernetes` grant.

## The decision — Model A vs Model B

**Model A (current draft):** GH Actions runner joins tailnet → k8s API via operator apiServerProxy →
ztest manages the run from outside.

**Model B:** GitHub webhook → the **already-deployed** Argo Events pipeline (`github-zaino`
EventSource + EventBus + `zaino-pr-deploy` Sensor, which already does serve/update/cleanup-ephemeral
on PR label/push/close) → an in-cluster Job runs ztest as a **pod ServiceAccount bound to
`ztest-remote`**. ztest does the same imperative management; only *where it runs and how it
authenticates* change.

**Correction that sharpened the framing (from the discussion):** don't say "Argo runs the tests and
ztest is a leaf." ztest is the **manager** in both models — it deploys/provisions/tests/teardowns.
So Model B reuses the Argo **event entry point**, NOT the deploy workflows (those overlap with what
ztest already does). ztest keeps its full role and dev/CI parity (locally→kind, CI→pod SA, same
binary + same `cluster check`).

**Why B (leaning):**
- **Trust.** Both models grant ztest the same broad `ztest-remote` rights (it must, to make
  namespaces/storage/obs), and in both the PR test code runs next to that grant — so neither is safe
  by identity alone; containment matters either way. What B changes is *exposure*: an in-cluster,
  short-lived, revocable **pod token** with no external attack surface, vs a tailnet network identity
  on a GitHub-hosted machine **plus** a new inbound apiServerProxy.
- **B deletes work, including on the machines repo.** The `cap/kubernetes` grant + `tag:ztest-runner`
  + 2nd OIDC client are unwritten; B removes the need for them entirely.

## Substrate vs orchestration split (the actionable conclusion)

- **~90% of both PRs is model-agnostic substrate — land it either way:** all of zot + TopoLVM +
  `cluster.toml` (devops#9), and **all of machines#15**.
- **Only Model-A-specific bits in devops#9:** the one line `apiServerProxyConfig: "true"`, and the
  binding *subject* (`Group/ztest-ci` → swap to the Job's ServiceAccount for B). The `ztest-ci/`
  README reasoning (reuse `ztest-remote`, ordering, never ArgoCD-manage it) stays valid verbatim.
- Migration A→B is cheap: drop one line, swap the binding subject, cancel the unwritten machines
  tailnet-identity work, and build one Job + one Sensor trigger + GitHub App status reporting.

## Side thread — zot as the *standard* build registry, not a ztest side-artifact

devops#9 brands zot as "the ztest build registry". Argued it should be the declarative default for
the standard BuildKit flows:
- `build-zaino` today is **Docker-Hub-shaped**: pushes to `zingodevops/zaino` with a mounted
  `docker-registry-creds`, and its skip-if-exists probe hits `hub.docker.com/v2/...`. That's inverted
  layering — the registry should be a platform primitive with build-zaino as a consumer.
- Concrete promote: flip the `registry` default to `zot.zot.svc.cluster.local:5000/zaino`; add
  `registry.insecure=true` to the buildctl output (zot is http://); drop the creds mount
  (unauthenticated → also removes an imperative `kubectl create secret` step = GitOps win); replace
  the Hub existence probe with an OCI `/v2/.../tags/list`. Pull side already works via machines#15's
  mirror.
- **Cost of promotion:** zot becomes load-bearing infra — 50Gi local-path, single node, no expansion,
  sized for "~10 images". Needs a GC/retention policy (`extensions.scrub`) + capacity rethink.
- **Carve-out:** keep Docker Hub/ghcr for *release/distribution* images (must survive a node dying).
  zot **complements**, doesn't replace. Deferred ("we'll see about zot later").

## Follow-ups

- Post the note ✅ (issuecomment-5516873401). Awaiting Eli's take on A vs B.
- Open questions raised for either model: can `ztest-remote` be scoped tighter (namespace-scoped, or
  reduced after ns creation) so untrusted PR code isn't co-resident with cluster-wide rights? Does
  ztest build the image itself or consume `build-zaino`'s output?
- Optional naming cleanup: `tag:ci` (machines deploy) is misleadingly generic once a test identity
  exists; consider `tag:node-deployer`.

## Pivot — converged on Model A done *right* (not B)

Eli pushed back on the in-cluster/Argo lean, and the pushback mostly held:
- **Scoping the run identity settles the main trust worry.** `ztest cluster setup` (one-time,
  admin, creates the ClusterRole) vs the per-run role is a clean split. Confirmed `ztest-remote`
  (ztest `policy.rs`) is already least-privilege *by resource* (namespaces/pods/services/cm/pvc/
  resourcequotas + read-only nodes/SAs; no secrets, no rbac, no escalation) — though still
  cluster-wide by namespace (tightening to `ztest-*` is a non-trivial ztest change, deferred).
- **ztest runs fine from anywhere** — it's an API client. And the image build is in-cluster (build
  pod via `pods/exec`), tests dial via `pods/portforward` — so loopback-only zot is NOT a blocker
  for an external runner.
- **Native Actions DX** (checks/comments/re-run) is real. Correction to the posted note: Argo does
  NOT rule out rich reporting (a GitHub App can post check-runs/annotations from anywhere — the
  gate poller already posts outbound); what's Actions-only is the native *log stream + run controls*.

**Decisive refinement (nachog):** use **federated OIDC**, not a stored OAuth/SA secret, and a
dedicated **`tag:ztest-runner`** — `tag:ci` is the machines *deploy* identity (admin/operator/
ACL-write) and OIDC is per-repo. Federation removes the one durable objection to Actions (no
long-lived exfiltratable credential; GitHub mints a short-lived token per run). If fully federated,
you KEEP the apiServerProxy + impersonation (that's what avoids a stored kube credential) — don't
drop it.

**Converged design:** GH Actions → federated OIDC (repo:zaino) → join tailnet as `tag:ztest-runner`
→ operator apiServerProxy → impersonate group `ztest-ci` → `ztest-remote` (scoped) → ztest builds
in-cluster/deploys/tests/teardown → Actions-native reporting.

## PRs landed (stacked on Eli's #9 / #15)

- **machines#16** (ready, base main) — declares `tag:ztest-runner`; one least-privilege grant to
  `tag:k8s-operator:443` + `cap/kubernetes` impersonate group `ztest-ci`; no node/SSH; new ACL
  `tests` invariant (proxy yes, nodes no). Inert until a device wears the tag → safe to merge early.
  **Merge unblocks creating the federated OAuth client.**
- **devops#10** (base `feat/ztest-infrastructure`, stacks on #9) — README `tag:ci` → `tag:ztest-runner`.
- **zaino#1507** (draft, base dev) — `.github/workflows/ztest-live.yml`: federated tailnet join,
  label + protected-environment fork gate, `cargo install ztest_cli` (0.1.10), `ztest cluster
  add/check`, run `live-tests/sync`. Depends on #1458 (the suite) + the machines/OAuth prereqs.

**Manual prerequisites (nachog, not in any PR):** merge #16 → create 2nd Tailscale OAuth client
(federated repo:zaino, auth_keys, owns tag:ztest-runner) → set zaino repo vars TS_OIDC_CLIENT_ID /
TS_OIDC_AUDIENCE / ZTEST_CLUSTER_CONFIG_URL → `ztest cluster setup` on the cluster → #9 binding.

**Open items:** ztest `sync --watch` exit-code semantics (provisional CLI — may need `sync status
--json` gating); operator RBAC must permit impersonating group `ztest-ci`; `cancel-in-progress` may
leak run namespaces (add `if: cancelled()` teardown); optional: tighten `ztest-remote` to `ztest-*`.
