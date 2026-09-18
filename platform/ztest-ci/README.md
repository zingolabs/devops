# ztest-ci

CI runs zaino's live suite on `ubuntu-latest`, joins the tailnet as `tag:ztest-runner`, and
reaches the API server through the operator's proxy. **No kube credential exists in GitHub** —
the runner authenticates as its tailnet identity, and the grant in
[`machines/tailscale/policy.hujson`](https://github.com/zingolabs/machines) maps it to the
Kubernetes group `ztest-ci`. This directory is the other half: what that group may do.

## Groups

| Group      | Who                             | Role                               |
| ---------- | ------------------------------- | ---------------------------------- |
| `ztest-ci` | nodes tagged `tag:ztest-runner` | `ztest-orchestrator`, cluster-wide |

The only one. CI cannot be a ServiceAccount — Tailscale's grant emits only `Impersonate-Group`,
and an SA would mean a stored token. Note Tailscale falls back to a node's *tags* as groups when
no grant applies, so a new tag allowed to reach the operator silently becomes a group.

## ServiceAccounts

Created by `ztest cluster setup`, not by ArgoCD.

| ServiceAccount               | Role                                           | Runs                              |
| ---------------------------- | ---------------------------------------------- | --------------------------------- |
| `ztest/ztest-orchestrator`   | `ztest-orchestrator`, cluster-wide             | the CLI; sync drivers             |
| `ztest/ztest-driver`         | `ztest-driver`, RoleBinding per test namespace | driver pods — untrusted test code |
| `ztest-build/ztest-buildkit` | none                                           | the build pod — untrusted source  |

`ztest-orchestrator` is not admin: no rbac-write, no secrets-read, no cluster-admin.

## Why a policy and not narrower RBAC

The group is bound by a ClusterRoleBinding, so its verbs apply in every namespace. RBAC has no
namespace-prefix scoping, and neither fix works: narrowing the role breaks `check_access` (an
SSAR over every rule the CLI renders) at run start, and per-namespace RoleBindings cannot be
pre-created because test namespaces are born at run time.

So `policy.yaml` bounds the reach instead. It matches on identity, which also covers the two
ServiceAccounts:

| Rule | Stops                                                                             |
| ---- | --------------------------------------------------------------------------------- |
| 1    | writes outside the `ztest-*` namespaces or a `ztest.io/role=test-env` one         |
| 2    | creating, deleting or relabelling any other namespace                             |
| 3    | host network/PID/IPC, hostPath, host ports, privileged, added capabilities        |
| 4    | naming any ServiceAccount but the four ztest ones                                 |
| 5    | any RBAC write but the per-test RoleBinding, pinned to `ClusterRole/ztest-driver` |

Rule 4 has no RBAC equivalent: `pods: create` lets a pod name any ServiceAccount in its
namespace and read that token from inside.

**Rollout.** The binding ships `validationActions: [Audit, Warn]` — logged, nothing rejected.
Flip to `[Deny]` after a green live-tests run. Exercised by
`ztest/tests/admission/policy-test.sh`.

## Ordering

`ztest cluster setup` creates the ClusterRoles; ArgoCD only references them. A `roleRef` to a
ClusterRole that does not exist yet is legal and grants nothing, so either may be applied first.
ArgoCD must never manage `ztest-orchestrator` itself — ztest stamps a `ztest.io/rules-hash` on it
and verifies it at run start. Same boundary as [`platform/zot`](../zot/README.md).

`ztest-ci-preflight` grants exactly one thing the run role never will: `get` on those two
ClusterRoles by name, so `ztest cluster check` can read that annotation.
