Deploy a zaino instance using the deploy-ephemeral Argo WorkflowTemplate.

Parse the user's request to determine:
1. **What ref to deploy** — could be a PR number, branch name, commit hash, or RC tag
2. **Whether to build or use a pre-built image** — if user says "deploy rc7" and the tag exists on Docker Hub, use `zaino-tag`; if they give a branch/commit, use `ref`
3. **Namespace name** — derive from the ref using the naming convention below
4. **Extra options** — ephemeral mode, public exposure, testnet, etc.

## Namespace naming convention

| Input type | Pattern | Example |
|------------|---------|---------|
| PR number + commit | `pr-<number>-<shorthash>` | `pr-1294-d03cde0d` |
| RC tag (e.g. 0.5.0-rc.7) | `rc<N>-<shorthash>` | `rc7-29e8d4c` |
| RC tag + qualifier | `rc<N>-<qualifier>-<shorthash>` | `rc7-ephemeral-29e8d4c` |
| Named purpose | `<purpose>-<shorthash>` | `bisect-1112-a4f2c01` |
| Branch name | `<sanitized-branch>-<shorthash>` | `fix-sync-d03cde0` |

Rules: always include short commit hash, no `v` prefix, DNS-1123 (lowercase + hyphens, max 63 chars).

## Steps

1. If the user provides a PR number or branch, resolve the commit hash:
   ```bash
   git -C ~/zingo/zingolabs/zaino rev-parse <ref>
   # or for remote PRs:
   gh pr view <number> -R zingolabs/zaino --json headRefOid,headRefName -q '.headRefOid'
   ```

2. If using a tag, check if image exists on Docker Hub:
   ```bash
   # Image naming: zingodevops/zaino:<tag>-<features-suffix>
   # e.g. zingodevops/zaino:0.5.0-rc.7-no-tls-with-prometheus
   ```

3. Construct the argo submit command. Always confirm with the user before running:
   ```bash
   argo submit --from workflowtemplate/deploy-ephemeral -n argo \
     -p namespace=<derived-namespace> \
     [-p ref=<full-40-char-hash> | -p zaino-tag=<tag>] \
     [additional params...]
   ```

4. Common additional params to suggest when relevant:
   - `-p zaino-env=ZAINO_EPHEMERAL_FINALISED_STATE=true` — if user wants wallet-ready immediately (no full sync needed)
   - `-p expose-public=true -p tailscale=true` — if user wants external access
   - `-p use-zaino-cache=true` — if user wants to start from a cached zaino DB
   - `-p metrics=false` — for older refs without prometheus support
   - `-p network=testnet` — for testnet deploys

5. After submission, provide monitoring commands:
   ```bash
   argo watch -n argo <workflow-name>
   argo logs -n argo <workflow-name> --follow
   ```

## Important caveats
- Use FULL 40-char commit hashes (BuildKit needs them for remote clone)
- `cargo-features` defaults to `no_tls_with_prometheus` — correct for all recent refs
- Public exposure (`expose-public=true`) is UNAUTHENTICATED — only for time-boxed tests
- Cleanup when done: `argo submit --from workflowtemplate/cleanup-ephemeral -n argo -p namespace=<ns>`

$ARGUMENTS
What to deploy (PR number, branch, commit hash, or RC tag). Optionally include qualifiers like "with public endpoint", "ephemeral mode", "testnet", etc.
