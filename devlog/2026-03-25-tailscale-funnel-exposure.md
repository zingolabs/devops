# 2026-03-25: Tailscale Funnel & Service Exposure

## Summary

Exposed tryout-3 zaino as a public TLS-enabled gRPC service via Tailscale Funnel. Added Tailscale exposure for golden-mainnet and golden-testnet zaino services (tailnet-only).

## Tailscale Funnel for gRPC (tryout-3)

### Problem

Need to expose zaino gRPC (port 8137) to the public internet with TLS for external wallet testing.

### Approach: Kubernetes Operator Ingress (failed)

The Tailscale operator's Ingress approach (`tailscale.com/funnel: "true"` annotation) doesn't work for gRPC:
- Operator logs: `"Ingress contains no valid backends"`
- The ingress reconciler expects HTTP backends with ports named `http`/`https` or port 443
- gRPC protocol handling via Ingress is an [open feature request](https://github.com/tailscale/tailscale/issues/13854)

### Approach: CLI `tailscale funnel` with `--tls-terminated-tcp` (works)

Exec into the tailscale proxy pod and configure funnel directly:

```bash
kubectl exec -n tailscale ts-zaino-rj8tl-0 -c tailscale -- \
  tailscale funnel --yes --bg --tls-terminated-tcp=443 tcp://10.43.51.28:8137
```

- `--tls-terminated-tcp=443`: Tailscale accepts TLS on port 443, terminates it, forwards plaintext TCP
- The `-no-tls` zaino image works fine since Tailscale handles TLS termination
- Let's Encrypt cert auto-provisioned for `tryout-3-zaino.vaquita-altair.ts.net`
- Public DNS resolves to Tailscale Funnel relay IPs (208.111.34.x), not tailnet IPs
- Verified working from a non-tailnet machine via grpcurl

### Caveat

This config is **ephemeral** - lost on pod restart. Needs a persistent solution (post-start hook, operator config, or similar).

## Golden Services Tailscale Exposure

Added `tailscale.com/expose: "true"` to golden-mainnet and golden-testnet zaino services for tailnet-internal access (no funnel needed).

### Design Decision: Chart vs Overlay

Discussed whether tailscale annotations belong in the zcash-stack chart or as a kustomize overlay in the devops repo. The clean answer is overlay (tailscale is a deployment concern, not a chart concern), but for now we added `service.annotations` support to the chart directly. This is a shortcut - **TODO: revisit with ArgoCD kustomize patches on Helm sources** for proper separation of concerns.

### Changes

**zcash-stack chart:**
- `templates/zaino-service.yaml` - added `{{- with .Values.zaino.service.annotations }}` block
- `values.yaml` - added `service.annotations: {}` default

**devops repo:**
- `clusters/production/values/golden-mainnet.yaml` - added `tailscale.com/expose: "true"`
- `clusters/production/values/golden-testnet.yaml` - added `tailscale.com/expose: "true"`

## Key Learnings

1. **Tailscale Funnel ports**: Only 443, 8443, 10000 are allowed
2. **gRPC over Funnel**: Use `--tls-terminated-tcp`, not the HTTP Ingress path
3. **DNS behavior**: Tailnet hosts resolve to 100.x.x.x IPs; Funnel-enabled hosts resolve to 208.x.x.x relay IPs from public DNS
4. **Operator proxy pods**: Each `tailscale.com/expose` service gets a `ts-*` proxy pod in the `tailscale` namespace, identifiable via `tailscale.com/parent-resource-ns` label
