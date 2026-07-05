Cleanup an ephemeral zaino deployment.

Given a namespace name (or enough context to derive it), run:

```bash
argo submit --from workflowtemplate/cleanup-ephemeral -n argo \
  -p namespace=<namespace>
```

This will:
1. Reap the Tailscale device (if expose-public was used) — best-effort
2. Delete the namespace and all resources within
3. Clean up cluster-scoped VolumeSnapshotContents

Safety: only namespaces labeled `zcash-stack/ephemeral=true` can be cleaned up.

If user doesn't specify the exact namespace, list ephemeral namespaces:
```bash
kubectl get ns -l zcash-stack/ephemeral=true --context zingo-infra
```

$ARGUMENTS
Namespace to clean up (or "list" to show active ephemeral deployments)
