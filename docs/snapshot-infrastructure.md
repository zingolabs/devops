# Snapshot Infrastructure

This document describes the architecture for creating and distributing chain state snapshots for Zebra and Zaino.

## Purpose

Syncing Zcash blockchain data takes time - days for mainnet. This infrastructure provides:

- **Pre-synced snapshots** for developers testing release candidates
- **Signed public snapshots** so users can skip the sync process
- **Instant rollback** capability before risky upgrades

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                 Server                                      │
│                                                                             │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │                        Kubernetes (k3s)                           │    │
│   │                                                                   │    │
│   │    ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐            │    │
│   │    │ Zebra   │  │ Zebra   │  │ Zaino   │  │ Zaino   │            │    │
│   │    │ Mainnet │  │ Testnet │  │ Mainnet │  │ Testnet │            │    │
│   │    └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘            │    │
│   │         │            │            │            │                  │    │
│   │         └────────────┴─────┬──────┴────────────┘                  │    │
│   │                            │                                      │    │
│   │                     ┌──────▼──────┐                               │    │
│   │                     │   TopoLVM   │  ← Kubernetes CSI driver      │    │
│   │                     │             │    provisions volumes,        │    │
│   │                     └──────┬──────┘    creates snapshots          │    │
│   │                            │                                      │    │
│   │                     ┌──────▼──────┐                               │    │
│   │                     │  Kanister   │  ← Orchestrates:              │    │
│   │                     │             │    stop → snapshot → resume   │    │
│   │                     └─────────────┘    → compress → upload        │    │
│   │                                                                   │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│                                 │                                          │
│   ┌─────────────────────────────▼─────────────────────────────────────┐    │
│   │                      LVM Thin Pool                                │    │
│   │                                                                   │    │
│   │   Logical volumes for each workload, carved from shared pool.    │    │
│   │   Snapshots are copy-on-write: instant creation, space-efficient │    │
│   │                                                                   │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ compress (zstd) + sign (minisign)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Cloudflare R2                                    │
│                                                                             │
│   S3-compatible object storage with free egress.                           │
│   Serves as public CDN for snapshot distribution.                          │
│                                                                             │
│   snapshots.zingolabs.org/                                                 │
│   ├── manifest.json                                                        │
│   ├── zebra/mainnet/zebra-mainnet-2860000.tar.zst                         │
│   ├── zaino/mainnet/zaino-mainnet-v0.9.0-2860000.tar.zst                  │
│   └── ...                                                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                    Developers, users, CI pipelines
                    download and verify signatures
```

## Component Choices

### LVM Thin Pools

**What**: Linux Logical Volume Manager with thin provisioning.

**Why**:
- Instant snapshots via copy-on-write (milliseconds, regardless of data size)
- Space-efficient: snapshots only store changed blocks
- Native Linux tooling, no extra daemons
- TopoLVM integrates it with Kubernetes CSI

**Alternative considered**: Longhorn. Rejected because its distributed storage overhead (5-17x slower) isn't justified for a single-node setup.

### TopoLVM

**What**: Kubernetes CSI driver that provisions volumes from LVM.

**Why**:
- Bridges Kubernetes PVC requests to LVM operations
- Supports CSI VolumeSnapshot API
- Designed for local storage scenarios
- Maintained by the Kubernetes community

**How it works**: When a StatefulSet requests storage, TopoLVM creates a logical volume from the thin pool. When a VolumeSnapshot is requested, it creates an LVM snapshot.

### Kanister

**What**: CNCF sandbox project for application-level data management.

**Why**:
- Orchestrates the stop → snapshot → resume workflow via "Blueprints"
- Handles the complexity of quiescing stateful applications
- Can export snapshots to any S3-compatible storage
- Open source, works standalone (doesn't require Kasten K10)

**Why quiescing matters**: Zebra uses RocksDB which holds write locks. Taking a snapshot while the database is active risks inconsistency. Kanister scales the StatefulSet to zero, takes the snapshot, then scales back up.

### Cloudflare R2

**What**: S3-compatible object storage with zero egress fees.

**Why**:
- $0.015/GB/month storage, $0 egress (free downloads)
- Built-in global CDN
- S3 API compatible (works with standard tools)
- Simple: one service, no separate CDN configuration

**Alternative considered**: Backblaze B2 + Cloudflare CDN. Cheaper storage but more complex setup. Not worth the ~$5/month savings.

### Minisign

**What**: Simple, single-purpose signing tool using Ed25519.

**Why**:
- Designed specifically for signing files
- Simpler than GPG (no web of trust, key management)
- Small signatures, fast verification
- Users can verify snapshots came from ZingoLabs

## Snapshot Workflow

1. **Trigger**: Manual ActionSet or scheduled CronJob
2. **Quiesce**: Kanister scales StatefulSet to 0 replicas
3. **Snapshot**: TopoLVM creates LVM snapshot (instant)
4. **Resume**: Kanister scales StatefulSet back to 1
5. **Export**: Mount snapshot read-only, compress with zstd
6. **Sign**: Create minisign signature
7. **Upload**: Push to R2 via rclone
8. **Manifest**: Update manifest.json with new snapshot metadata
9. **Cleanup**: Remove local snapshot to free space

Total downtime: seconds (just the quiesce/resume). Compression and upload happen while workloads are running.

## Public Distribution

### Manifest

`manifest.json` provides an index of available snapshots:

```json
{
  "version": 1,
  "updated": "2026-03-14T12:00:00Z",
  "public_key": "RWTxxxxxx...",
  "snapshots": {
    "zaino": {
      "mainnet": {
        "latest": "zaino-mainnet-v0.9.0-2860000.tar.zst",
        "height": 2860000,
        "zaino_version": "0.9.0",
        "size_bytes": 89000000000,
        "sha256": "..."
      }
    }
  }
}
```

### Verification

Users verify snapshots before use:

```bash
curl -O https://snapshots.zingolabs.org/zaino/mainnet/zaino-mainnet-v0.9.0-2860000.tar.zst
curl -O https://snapshots.zingolabs.org/zaino/mainnet/zaino-mainnet-v0.9.0-2860000.tar.zst.minisig

minisign -V -p zingolabs.pub -m zaino-mainnet-v0.9.0-2860000.tar.zst
```

## Replicating This Setup

To set up similar infrastructure on another cluster:

1. **Storage layer**: Configure LVM thin pool on your data disk(s)
2. **CSI driver**: Install TopoLVM, pointing at your volume group
3. **Snapshot controller**: Install Kubernetes external-snapshotter
4. **Orchestration**: Install Kanister, create Blueprints for your workloads
5. **Export target**: Create S3 bucket (R2, B2, MinIO, etc.)
6. **Signing**: Generate minisign keypair, publish public key

The specific manifests live in this repository under `platform/` and can be adapted for different environments.
