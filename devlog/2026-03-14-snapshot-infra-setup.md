# 2026-03-14: Snapshot Infrastructure Setup

Setting up LVM + TopoLVM + Kanister + R2 on tekau for chain state snapshots.

## Starting State

- Server: tekau
- Disks:
  - nvme0n1: 1.8TB - root filesystem (/)
  - nvme1n1: 1.8TB - mounted at /data (raw ext4, no LVM)
- Existing data on /data:
  - /data/zebra: 269GB (mainnet + testnet synced)
  - /data/zaino: 43GB
- k3s: not installed yet

## Goal

Convert nvme1n1 to LVM thin pool, install k3s with TopoLVM, restore data, set up snapshot pipeline to R2.

---

## Phase 1: LVM Setup

### Backup existing data

Data moved off nvme1n1 prior to starting.

### Unmount and reformat

```bash
sudo umount /data
# Commented out fstab entry: /dev/nvme1n1 /data ext4 defaults 0 2
sudo wipefs -a /dev/nvme1n1
# output: /dev/nvme1n1: 2 bytes were erased at offset 0x00000438 (ext4): 53 ef
```

### Create LVM structure

```bash
sudo pacman -S lvm2   # was not installed
sudo pvcreate /dev/nvme1n1
sudo vgcreate data_vg /dev/nvme1n1
sudo lvcreate -L 1.7T --thinpool thinpool data_vg
# warnings about chunk size and zeroing - ignored, not critical
```

### Verify

```bash
sudo lvs -a data_vg
#   LV               VG      Attr       LSize   Pool Origin Data%  Meta%
#   [lvol0_pmspare]  data_vg ewi------- 112.00m
#   thinpool         data_vg twi-a-tz--   1.70t             0.00   10.41
#   [thinpool_tdata] data_vg Twi-ao----   1.70t
#   [thinpool_tmeta] data_vg ewi-ao---- 112.00m
```

**Phase 1 complete.** Thin pool ready: 1.7 TiB available.

---

## Phase 2: k3s + TopoLVM

### Install k3s

```bash
# TODO: run this
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable local-storage
```

### Install snapshot controller

```bash
# TODO: run these
# CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.0.1/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.0.1/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.0.1/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.0.1/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.0.1/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

### Install TopoLVM

```bash
# TODO: run these
helm repo add topolvm https://topolvm.github.io/topolvm
helm install topolvm topolvm/topolvm \
  --namespace topolvm-system --create-namespace \
  --set deviceClasses[0].name=thin \
  --set deviceClasses[0].volumeGroup=data_vg \
  --set deviceClasses[0].type=thin \
  --set deviceClasses[0].thinPoolName=thinpool
```

---

## Phase 3: Restore Data

TBD - need to figure out how to restore into PVCs before StatefulSets start.

Options:
1. Create PVCs manually, mount, rsync, then deploy StatefulSets
2. Use init containers that pull from backup location
3. Deploy with empty PVCs, manually copy after mount

---

## Phase 4: Kanister

TBD

---

## Phase 5: R2 Setup

TBD

---

## Notes / Decisions

- Chose LVM thin pool over Longhorn due to 5-17x performance overhead on single node
- Chose R2 over B2+Cloudflare for simplicity (same effective cost)
- Chose minisign over GPG for simplicity

## Issues Encountered

(will fill in as we go)
