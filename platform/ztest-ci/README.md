# ztest-ci — CI's grip on the cluster

GitHub Actions runs zaino's live suite on `ubuntu-latest`, joins the tailnet as
`tag:ztest-runner`, and reaches the API server through the operator's proxy. **No kube
credential is minted or stored in GitHub** — the runner authenticates as its
tailnet identity, and the tailnet grant maps that identity to the Kubernetes
group `ztest-ci`:

```json
"app": {
  "tailscale.com/cap/kubernetes": [
    {"impersonate": {"groups": ["ztest-ci"]}}
  ]
}
```

That grant lives in [`machines/tailscale/policy.hujson`](https://github.com/zingolabs/machines);
this directory is the other half — the binding that gives the group anything at all.

## Why it binds `ztest-remote`

`ztest-remote` is ztest's own single source of truth for what a run needs
(`src/resource/impls/policy.rs`): one rule list drives both the ClusterRole and
the `check_access` self-check at run start, so a missing verb fails by name
instead of as a mid-run 403. Namespace `create`/`patch`/`delete` is in it —
per-run namespaces are the run identity's job.

Reusing it means CI's grip cannot drift from what a run actually needs. Writing a
parallel CI role here would guarantee that drift.

## Ordering

`ztest cluster setup` creates the ClusterRole; ArgoCD only *references* it. So:

- This binding may be applied first. A `roleRef` to a ClusterRole that does not
  exist yet is legal and simply grants nothing until setup runs.
- ArgoCD must never manage `ztest-remote` itself. ztest stamps a
  `ztest.io/rules-hash` annotation on it and verifies it at run start; a copy
  maintained here would fail that check the moment ztest's rule list moved ahead
  of a devops PR. Same boundary as [`platform/zot`](../zot/README.md).

## Verifying

From a runner (or any `tag:ztest-runner` machine):

```bash
tailscale configure kubeconfig tailscale-operator
ztest cluster check
```

`check` probes every `(resource, verb)` pair the role grants via
`SelfSubjectAccessReview`, so it names any gap precisely rather than failing
twenty minutes into a run.
