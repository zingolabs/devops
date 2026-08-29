# zot — ztest build registry

OCI registry for the artifacts [ztest](https://github.com/zingolabs/ztest) builds
on-cluster: the per-run `ztest-runner:dev-<run-id>` image and the
content-addressed `dev-<hash>` component images.

Published zaino releases are unaffected — those keep going to `zingodevops/zaino`
through the `build-zaino` WorkflowTemplate. What lands here is per-run, roughly a
gigabyte, and only ever pulled back into this cluster, so round-tripping it
through Docker Hub would be pure waste.

## Why it carries no credential

The tailnet ACL is the boundary, and it is the only one. Everyone who can reach
this registry already holds a kubeconfig for the cluster, so a push credential
would gate nothing that `kubectl apply` does not already allow — it would only
add a secret to rotate and a manual step to repeat.

Two consequences, both load-bearing:

- **Never add a `tailscale.com/funnel` annotation.** That would put an
  anonymous-write registry on the open internet.
- **Read must stay anonymous even if auth is reconsidered.** ztest creates a
  fresh namespace per run, so an `imagePullSecret` would have to be minted in
  every one of them.

There is nothing to seal and nothing to apply by hand: ArgoCD owns this
component end to end.

## Wiring ztest to it

The registry address and the storage/snapshot classes live in
[`clusters/production/zingolabs-cluster.toml`](../../clusters/production/zingolabs-cluster.toml),
which is the reviewed source of truth — it changes in the same PR that changes
the cluster:

```bash
ztest cluster add zingo-infra --kube-context <ctx> \
  --extra-config https://raw.githubusercontent.com/zingolabs/devops/main/clusters/production/zingolabs-cluster.toml
```

Identity stays in the operator's own kubeconfig; that file carries no credential.

`ztest cluster check` reports the resolved registry on the `image registry` row.

## Boundary

ArgoCD owns this registry, the StorageClasses and the VolumeSnapshotClasses.
It does **not** own anything in the `ztest` / `ztest-obs` / `ztest-<run-id>`
namespaces — those are `ztest cluster setup`'s and the run's.

That split is not stylistic. ztest stamps a `ztest.io/rules-hash` annotation on
the `ztest-remote` ClusterRole and verifies it at run start; a copy maintained
here would fail that check the first time ztest's rule list moved ahead of a
devops PR, and `selfHeal: true` would revert what setup applied. Same reasoning
as the ephemeral `preview-*` namespaces: no def claims them, so ArgoCD ignores
them.

## Retention

Everything here is reproducible from source, so the policy reclaims rather than
preserves. Two policies, first match wins:

- `ztest-runner` — per-run and disposable, keep the last 10 pushes
- everything else — `dev-<hash>` component images are content-addressed and can
  be weeks old while still referenced, so they survive on `pulledWithin` (30d)
  rather than push age, with the 5 most recent pushes kept regardless

GC runs every 6h against a 24h delay, so a blob is never collected out from under
an in-flight push.
