# 2026-03-21: Platform Spec and CLI Foundation

Defining the conceptual model for the infrastructure platform and scaffolding the CLI tool.

## Platform Spec

### The Stack

```
Wallet Clients
    ↓ gRPC / lightwalletd protocol
Zaino (indexer)
    ↓ RPC / library
Zebra (validator)
```

### Networks

| Network | Purpose | Sync Time |
|---------|---------|-----------|
| Regtest | Unit/integration tests | Seconds |
| Testnet | Real validation, sandblast heights | Hours |
| Mainnet | Production validation | Days |

### Deployment Types

**Golden Deployments** (always running):
- Maintain synced state
- Produce periodic snapshots
- Pinned to known-good versions (stable or trusted rc)

**Ephemeral Deployments** (on-demand):
- Test specific refs against real chains
- Restore from golden snapshot (skip sync)
- Spin up → test → report → tear down

### Test Scenarios (by cost/duration)

**Fast (minutes):**
- Wallet interactions on pre-synced state
- Serve requests at tip
- API compatibility checks
- Basic health checks

**Medium (hours):**
- Sync through sandblast (specific hard height range)
- Sync from recent snapshot to tip
- Mid-sync scenarios
- Validator tip vs indexer tip ratio combinations

**Slow (days):**
- Full chain sync from scratch
- Extended soak testing
- Load testing

### GitHub Event → Test Matrix (Future)

| Event | Fast | Medium | Slow |
|-------|------|--------|------|
| PR → dev | Required | Optional* | Skip |
| Merge → dev | Auto | Auto | Skip |
| dev → rc gate | Auto | Auto | Triggered** |
| rc tag cut | Auto | Auto | Required |
| rc → stable | Auto | Auto | Must have passed |

*PR label "test:medium" triggers
**If not run recently for this ref

### Version Compatibility

Zaino depends on Zebra two ways:
1. Library dependency (Cargo.toml) - compile time
2. Runtime RPC/protocol - must match

For ephemeral deploys, need to answer: "What zebra versions can this zaino ref talk to?"

Options:
- A) Parse Cargo.toml, infer zebra version → deploy that
- B) Maintain explicit compatibility matrix in repo
- C) Test against multiple zebra versions (matrix deploy)

Start with (A), add (C) for rc gate.

### Golden Deployment Variants

```yaml
golden_deployments:
  testnet:
    zebra:
      - version: stable
      - version: rc  # for testing zaino against upcoming zebra
    zaino:
      - version: stable
      - version: rc
  mainnet:
    zebra:
      - version: stable
    zaino:
      - version: stable
      - version: rc  # only after testnet rc proves stable
```

## CLI Tool

### Structure

```
cli/src/
├── main.rs           # Entry point
├── lib.rs            # Module declarations
├── cli.rs            # Clap definitions, dispatch
├── commands.rs       # mod declarations
├── commands/
│   ├── gen_crds.rs   # CRD generation
│   └── snapshot.rs   # Snapshot management (stub)
├── crds.rs           # CRD module root
└── crds/
    └── snapshot_set.rs  # SnapshotSet CRD type
```

### SnapshotSet CRD

```rust
#[derive(CustomResource)]
#[kube(group = "zcash.zingolabs.org", version = "v1alpha1", kind = "SnapshotSet")]
pub struct SnapshotSetSpec {
    pub network: Network,      // mainnet or testnet
    pub height: u64,           // block height at snapshot
    pub zebra: ComponentSnapshot,
    pub zaino: ComponentSnapshot,
    pub tags: Vec<String>,     // e.g., "golden", "milestone"
}
```

### Domain Model Direction

Future layering:
```
CLI / Workflows
    ↓ "deploy zaino rc for PR #123"
Domain Logic
    ↓ "need latest zaino cache for testnet"
Models (CRDs)
    ↓ SnapshotSet, GoldenDeploy, EphemeralDeploy
Infrastructure (kube-rs)
    ↓ VolumeSnapshots, PVCs, StatefulSets
```

## ArgoCD Integration

### CMP Sidecar Approach

For generating CRDs at sync time (not committing generated YAML):

1. Build CLI into container image with `argocd-cmp-server`
2. Mount as sidecar to repo-server
3. CMP plugin calls `devops gen-crds`
4. ArgoCD applies output

Keeps ArgoCD stock (independent upgrades), only couples on cmp-server binary.

### Image Workflow

For now: build and push locally before git push.
Future: CI builds on tag, pin versions in manifests.

```bash
# Pre-push workflow
cargo build --release
docker build -t zingodevops/devops:$(git rev-parse --short HEAD) .
docker push zingodevops/devops:$(git rev-parse --short HEAD)
git push
```

## GitHub Integration (Future)

Three APIs available:
- **Deployments API** - track deployment lifecycle, environment URLs
- **Checks API** - rich feedback, annotations, re-run
- **Commit Status** - simple pass/fail indicators

Our CLI can report status, or workflows use `gh` CLI directly.

Branch protection can require deployment success before merge.

## Fixes Applied

### ApplicationSet path field collision
- Git file generator creates `.path` metadata field
- Our custom `path` field was overwritten
- Fix: renamed to `sourcePath`

### TopoLVM single-node anti-affinity
- Default 2 controller replicas with anti-affinity
- Can't schedule both on single node
- Fix: `controller.replicaCount: 1`

## Next Steps

1. Implement manual deploy command (`devops deploy create`)
2. Define deploy scenarios (fresh-sync, pre-synced)
3. Set up Argo Events for webhook triggering
4. Test manual trigger via curl/UI
5. Add GitHub status reporting later
