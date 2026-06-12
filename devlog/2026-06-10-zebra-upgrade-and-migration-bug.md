# 2026-06-10 — Zebra 5.0.0/5.1.0 upgrade, NU6.2, migration hang

## NU6.2 activation emergency

NU6.2 activates at mainnet height 3,364,600. Golden zebra on 4.4.1 was ~96 blocks away. Upgraded to 5.0.0, but the existing chain state had already forked past activation on old rules. Had to restore zebra PVC from the May 3 snapshot (pre-fork) and let it resync. Later upgraded to 5.1.0 which fixes a genesis-to-tip sync stall.

## Docker Hub multi-arch image mismatch

The `zfnd/zebra:5.0.0` tag resolves to different binaries per architecture. One variant reports `zebrad 4.0.0` instead of 5.0.0. Same issue on `4.5.3` tag. Workaround: pin the amd64 digest directly. The `5.1.0` tag also affected — pinned in ephemeral-mainnet values. Investigating root cause in a separate session.

## Schema migration v1.0→v1.2 hang (zaino#1202)

Deploying `v0.4.0_nu_6_2_alpha` against a golden snapshot (schema v1.0.0) causes:
1. 1.0→1.1 "metadata-only" migration (4ms) truncates the index from 3.36M to 32k blocks
2. 1.1→1.2 migration runs 18 min in silence
3. Process reports Ready, then hangs burning a full CPU core for 7+ hours with zero log output
4. gRPC server never starts, sync loop never starts

Comparison: 0.4.0-rc.2 against a v1.1.0 snapshot migrated cleanly and preserved the full index. The 1.0→1.1 step is the destructive one.

Reproduced 3 times across restarts, both on zebra 4.4.1 and 5.0.0. Filed as zaino#1202 with full forensics and logs.

## UID mismatch (devops#2)

The zaino 0.4.x images changed container UID from 2003 to 1000. The zcash-stack chart's init-perms container hardcodes `chown 2003:2003`. Every cached deploy of 0.4.x crashloops with `LmdbError(Other(13))` (permission denied). Workaround: patch init-perms to chown 1000:1000. Tracked in devops#2.
