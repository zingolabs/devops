Update golden namespace deployments to latest compatible zaino and/or zebra releases.

Golden deployments (`golden-mainnet`, `golden-testnet`) are the source of truth for
ephemeral deploy snapshots. They must track recent releases, but zaino/zebra compatibility
is not guaranteed — schema migrations can hang, NU upgrades can fork, and multi-arch
image tags can resolve to wrong binaries.

## Version pinning files (GitOps)

- `clusters/production/values/golden-mainnet.yaml` — zebra.image.tag + zaino.image.tag
- `clusters/production/values/golden-testnet.yaml` — same structure

Changes here are synced by ArgoCD automatically.

## Steps

### 1. Check current golden versions

```bash
grep -A2 "tag:" clusters/production/values/golden-mainnet.yaml
grep -A2 "tag:" clusters/production/values/golden-testnet.yaml
```

### 2. Check latest available releases

**Zebra:**
```bash
gh release list -R ZcashFoundation/zebra --limit 5
```

**Zaino:**
```bash
gh release list -R zingolabs/zaino --limit 5
# Also check Docker Hub for pre-built images:
# zingodevops/zaino:<tag>-no-tls-with-prometheus (preferred for golden)
# zingodevops/zaino:<tag>-no-tls
```

### 3. Assess compatibility

Before upgrading, check these known compatibility constraints:

**Hard constraints:**
- Zaino schema migrations: v1.0→v1.1 truncates index; v1.1→v1.2 can hang for hours.
  If a migration is involved, the golden deploy will be DOWN during migration — plan accordingly.
- NU (Network Upgrade) boundaries: zebra must support the current network rules.
  Upgrading zebra across an NU activation on existing state can fork (happened with NU6.2 + 4.4.1).
- Zaino UID change at 0.4.x: container UID changed from 2003 to 1000. The zcash-stack chart's
  init-perms must match (patched via fix-permissions step in ephemeral; golden chart should have it).

**Soft constraints:**
- Multi-arch image mismatch: some zebra tags (5.0.0, 5.1.0) resolved to wrong binaries on
  non-amd64. If the node is amd64-only this doesn't matter.
- Zaino cargo features: golden should use `-no-tls` (or `-no-tls-with-prometheus` for metrics).
  Verify the image exists on Docker Hub before committing.

**Recommended: test in ephemeral first:**
```bash
# Deploy the candidate versions in an ephemeral namespace
argo submit --from workflowtemplate/deploy-ephemeral -n argo \
  -p namespace=golden-test-<shorthash> \
  -p zaino-tag=<new-zaino-tag> \
  -p zebra-tag=<new-zebra-tag> \
  -p use-zaino-cache=true
```

Watch for:
- Clean startup (no crashloop)
- Schema migration completion (check logs for "migration complete" or schema version)
- Sync progress (should start advancing blocks)
- gRPC responsiveness (`GetLightdInfo` returns correct chain info)

### 4. Update values and commit

After verifying compatibility:

```bash
# Edit the values files
# clusters/production/values/golden-mainnet.yaml
# clusters/production/values/golden-testnet.yaml
```

Commit message style:
```
Bump golden deploys: zaino <new> (was <old>), zebra <new> (was <old>)
```

### 5. Monitor ArgoCD sync

After push, ArgoCD will detect the drift and sync. The StatefulSet will rolling-restart.

**Critical:** If zaino has a schema migration, it will be unavailable during migration.
Monitor with:
```bash
kubectl logs -n golden-mainnet -l app=zaino -f --context zingo-infra
```

### 6. Create fresh golden snapshots

Once the upgraded golden deploys are fully synced and healthy:

```bash
# Mainnet
argo submit --from workflowtemplate/snapshot-golden -n argo

# Testnet
argo submit --from workflowtemplate/snapshot-golden -n argo \
  -p network=testnet -p namespace=golden-testnet
```

New ephemeral deploys will auto-resolve these fresh snapshots.

## Known compatibility history

| Zaino | Zebra | Status | Notes |
|-------|-------|--------|-------|
| 0.4.1-no-tls | 5.1.0 | PRODUCTION | Current golden (2026-06) |
| 0.4.1-no-tls | 5.2.0 | BROKEN | Parse error: invalid consensus branch id |
| 0.5.0-rc.6 | 5.2.0 | WORKS | Tested ephemeral (2026-07-01) |
| 0.5.0-rc.7 | 5.2.0 | WORKS | Tested ephemeral (2026-07-02) |
| 0.4.0-rc.2 | 5.1.0 | WORKS | Schema v1.1, clean migration from v1.0 |
| 0.4.0_nu_6_2_alpha | any | BROKEN | Hangs on v1.0→v1.2 schema migration |

**Keep this table updated as new versions are tested.**

## Important notes

- All changes go through git — never `kubectl set image` on golden (ArgoCD will revert it)
- Testnet is a good canary — upgrade testnet first, wait a day, then mainnet
- After golden upgrade, old ephemeral snapshots may be incompatible with new zaino versions
  (e.g. if schema version changed). Consider creating fresh snapshots promptly.
- Remind user to update the devlog with the upgrade decision and any findings

$ARGUMENTS
Optional: specific versions to upgrade to (e.g. "zaino 0.5.0-rc.7 zebra 5.2.0"), or "check" to just show current state and available upgrades.
