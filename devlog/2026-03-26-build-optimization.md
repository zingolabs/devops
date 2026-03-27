# Zaino Build Optimization Experiment

Date: 2026-03-26

## Goal

Find the fastest way to build zaino images on the cluster for rapid iteration.

## Background

The zaino Dockerfile uses a Rust multi-stage build. Compiling the full dependency
tree from scratch takes ~2 minutes, and pushing layers adds more. We want to
minimize rebuild time when iterating on source changes.

## Baseline: Kaniko (no cache)

- Workflow: `build-zaino` (kaniko)
- Run: `build-zaino-ncfpz`
- Total time: **4m55s** (resolve-tag 3s + kaniko 4m)
- Notes: Clean build every time. Kaniko silently ignores `--mount=type=cache`
  in the Dockerfile, so cargo downloads + compiles everything from scratch.

## Previous attempt: Kaniko with remote layer cache

- Run: `build-zaino-j5bf5`
- Result: **Failed/hung** — kaniko spent 15+ minutes pushing large cache layers
  to `zingodevops/zaino-cache` on Docker Hub, then hung.
- Conclusion: Remote layer cache is not viable for large Rust builds. Upload cost
  exceeds any cache benefit, especially since source changes invalidate the
  expensive compilation layer anyway.

## Experiment A: Kaniko + cargo-chef Dockerfile

- Approach: Restructure the Dockerfile with cargo-chef to separate dependency
  compilation into its own layer. Dependencies only recompile when Cargo.toml
  or Cargo.lock changes.
- Stages: planner → cook (deps only) → builder (source only) → runtime
- Branch: `feature/cargo-chef-dockerfile` on zingolabs/zaino
- Run: `build-zaino-4j6qb`
- Cold build time: **8m39s**
- Notes: Slower than baseline. Kaniko has no persistent layer cache between runs
  (ephemeral pods, no PVC), so cargo-chef's extra stages (install cargo-chef twice,
  cook deps) are pure overhead. The cacheable cook layer is rebuilt from scratch
  every time.

## Experiment B: BuildKit with PVC cache

- Approach: Replace kaniko with BuildKit (rootless, daemonless). BuildKit natively
  supports `--mount=type=cache`, and we persist its state on a PVC between runs.
- The existing Dockerfile already has cache mounts for cargo registry, git, and
  target/ — BuildKit uses them automatically.
- Requires: PVC `buildkit-cache` (10Gi), seccomp/apparmor Unconfined
- Workflow: `build-zaino-buildkit`
- Run (cold): `build-zaino-buildkit-s9p2d` — **4m27s**
- Run (warm, same ref): `build-zaino-buildkit-h9f22` — **20s**
- Run (warm, src change): `build-zaino-buildkit-5dzbm` — **1m25s**

## Experiment A+B: BuildKit + cargo-chef

- Not tested. With BuildKit's `--mount=type=cache` keeping cargo registry/git/target
  warm on the PVC, incremental compilation already works. cargo-chef would only help
  on cold PVC (rare case), adding complexity without meaningful benefit.

## Conclusions

- **Kaniko is a dead end for Rust builds**: ignores `--mount=type=cache`, no persistent
  local cache, remote cache hangs on large layers, project archived by Google.
- **BuildKit + PVC is the clear winner**: 4m27s cold → 1m25s on src change → 20s warm.
  Rootless (UID 1000), no privileged mode needed. Requires seccomp/apparmor Unconfined
  scoped to the build pod only.
- **cargo-chef not worth it here**: adds complexity without benefit when BuildKit mount
  caches are warm. Only useful on cold PVC which is rare with persistent storage.
- **Decision**: Replaced kaniko with BuildKit as the sole builder in `build-zaino`.
