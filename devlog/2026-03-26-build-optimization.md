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
- Even without BuildKit cache mounts, kaniko can cache the cook layer since its
  inputs (recipe.json) only change when dependencies change.
- Status: Dockerfile drafted, needs PR to zingolabs/zaino
- Run: TODO
- Cold build time: TODO
- Warm build (source-only change): TODO

## Experiment B: BuildKit with PVC cache

- Approach: Replace kaniko with BuildKit (rootless, daemonless). BuildKit natively
  supports `--mount=type=cache`, and we persist its state on a PVC between runs.
- The existing Dockerfile already has cache mounts for cargo registry, git, and
  target/ — BuildKit uses them automatically.
- Requires: PVC `buildkit-cache` (10Gi), seccomp/apparmor Unconfined
- Workflow: `build-zaino-buildkit`
- Status: Workflow template created
- Run: TODO
- Cold build time: TODO
- Warm build (source-only change): TODO

## Experiment A+B: BuildKit + cargo-chef

- Both optimizations combined. BuildKit cache mounts keep cargo registry/git warm,
  and cargo-chef separates the dependency layer.
- Run: TODO
- Cold build time: TODO
- Warm build (source-only change): TODO

## Conclusions

TODO — fill in after running experiments.
