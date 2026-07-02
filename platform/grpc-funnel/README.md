# grpc-funnel

Expose a plaintext (h2c) gRPC backend on this Tailscale-only cluster as a
**public, standard gRPC-over-TLS** endpoint that wallets can plug in as a
lightwalletd server — no operator L7 Ingress, no hacky framing.

## Why it's shaped this way

The cluster has no public IP and no traditional ingress; the only path to the
internet is Tailscale Funnel. Two dead ends we hit and route around:

- The Tailscale **operator** Funnel is L7/Ingress-only and **cannot carry gRPC**.
- Funnel `--tls-terminated-tcp` (Tailscale terminates TLS) returns
  **"No ALPN negotiated"**, so standard gRPC clients reject the connection.

So the pod runs Funnel as **raw TCP passthrough** and terminates TLS at **nginx**
(which negotiates `h2` correctly) using a Tailscale-issued Let's Encrypt cert,
then `grpc_pass` (h2c) to the backend. The backend stays no-tls and untouched.

```
wallet ──TLS/h2──▶ Funnel :443 (passthrough) ─▶ nginx :8443 (TLS term, h2)
                                                    └─h2c─▶ backend:8137 (zaino)
```

Three containers: `tailscale` (containerboot + serve config), `certfetch`
(shares the tailscaled socket, runs `tailscale cert`), `nginx`.

## Restart durability

State lives on a PVC (`persistence.enabled`, default on). With ephemeral `mem:`
state a pod restart re-registers the node under a new name (`<hostname>-N`) and
the cert stops matching the funnel hostname — the historical breakage. The PVC
keeps the node identity **and** the cached cert across restarts.

Keep `hostname` unique per deployment so two live funnels never collide on the
same Tailscale node name.

## Usage

```sh
helm upgrade --install my-funnel platform/grpc-funnel/chart \
  --namespace my-ns \
  --set hostname=zaino-rc6 \
  --set tailnet=vaquita-altair.ts.net \
  --set backend=zaino.my-ns.svc.cluster.local:8137 \
  --set-string authkey.value=tskey-auth-xxxx   # or --set authkey.existingSecret=...
```

Public URL: `https://<hostname>.<tailnet>:443` (standard gRPC). Verify:

```sh
grpcurl zaino-rc6.vaquita-altair.ts.net:443 \
  cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo
```

Normally you don't call this directly — `deploy-ephemeral` drives it via
`expose-public: true`, which mints the authkey and installs this chart.

## Values

| key | default | notes |
|-----|---------|-------|
| `hostname` | `""` | DNS-1123 label; public URL is `<hostname>.<tailnet>` |
| `tailnet` | `""` | tailnet DNS suffix, e.g. `vaquita-altair.ts.net` |
| `backend` | `""` | h2c gRPC backend `host:port` |
| `authkey.value` | `""` | raw authkey; chart creates the Secret |
| `authkey.existingSecret` | `""` | Secret with key `TS_AUTHKEY` (alternative) |
| `persistence.enabled` | `true` | PVC-backed tailscale state (restart durability) |
| `persistence.storageClass` | `local-path` | RWO is fine (single replica, Recreate) |
| `allowFunnel` | `true` | public + **unauthenticated**; off = tailnet-only |

## Security

The public Funnel endpoint is **unauthenticated** — anyone with the URL can hit
the backend. Intended for time-boxed test exposure; tear down after (deleting
the namespace removes the pod/PVC/secret; `cleanup-ephemeral` also reaps the
Tailscale device so the node name is free to reuse).
