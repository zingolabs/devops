# 2026-03-24: Observability Stack & Zcash Monitoring Vision

## Summary

Added kube-prometheus-stack and loki-stack to zingo-infra cluster. Defined vision for unified zcash stack observability. Identified gap: no request tracing in zaino.

## Key Achievements

### Observability Stack Deployed

Full monitoring stack via GitOps:

| Component | Purpose |
|-----------|---------|
| Prometheus | Metrics collection and storage |
| Grafana | Visualization and dashboards |
| AlertManager | Alert routing |
| Loki | Log aggregation |
| Promtail | Log collection (DaemonSet) |
| node-exporter | Host metrics |
| kube-state-metrics | K8s object metrics |

Grafana exposed via Tailscale (`tailscale.com/expose: "true"` annotation).

### Configuration Decisions

**Storage:** Using `local-path` instead of `topolvm-thin`
- Grafana's initChownData fails on LVM volumes (chown on lost+found)
- local-path simpler for stateful apps that don't need thin provisioning benefits

**Authentication:** Secret-based, not hardcoded
```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
```

**Datasource management:** Single source of truth
- Loki datasource configured in kube-prometheus-stack values
- Disabled loki-stack's sidecar to avoid "multiple defaults" conflict
- All datasources managed in one place

**CRDs:** `includeCRDs: true` in kustomization
- Kustomize helmCharts doesn't render helm hooks
- This flag embeds CRDs directly without hook mechanism

### Gotchas Encountered

1. **CRD installation**: Prometheus operator creates nothing without CRDs. Kustomize doesn't support hooks, so `includeCRDs: true` is required.

2. **Datasource conflicts**: Both loki-stack and kube-prometheus-stack were setting `isDefault: true` on datasources → Grafana provisioning fails with "only one datasource per organization can be marked as default"

3. **Operator restart needed**: After CRD installation, operator may need restart to reconcile StatefulSets for Prometheus/AlertManager.

## Zcash Stack Observability Vision

### The Goal

Unified observability across: **Zebra (validator) → Zaino (indexer) → Wallets (clients)**

When something goes wrong, be able to correlate across all three:
- What was zebra's state at that moment?
- What was zaino doing?
- What did the wallet see?

### Desired Capabilities

1. **Correlated timeline view** - zebra block height, zaino sync height, wallet requests on same time axis
2. **Sync speed analysis** - `rate(sync_height[5m])` graphed over height ranges
3. **Latency correlation** - trace slowness to root cause (zebra behind? network? compute?)
4. **Error correlation** - wallet error → zaino logs → zebra state
5. **Request tracing** - follow individual wallet request through entire stack

### Proposed Metrics Standard

| Component | Metrics | Labels |
|-----------|---------|--------|
| Zebra | sync_height, peer_count, block_time, mempool_size | instance, network, version |
| Zaino | sync_height, grpc_latency, cache_hits, connections | instance, network, version |
| Wallet | requests_sent, response_latency, sync_progress, errors | wallet_id, connected_zaino, version |

### Current State

| Component | Metrics | Logs | Tracing |
|-----------|---------|------|---------|
| Zebra | ✅ `/metrics` endpoint | ✅ stdout | ❌ none |
| Zaino | ❌ coming soon | ✅ stdout | ❌ none |
| Wallets | ❌ none | varies | ❌ none |

## Open Question: Request Tracing in Zaino

**Problem:** When an external tester reports "zaino isn't responding correctly," how do we trace their specific request through the system?

Currently impossible - no correlation between:
- Wallet's outgoing request
- Zaino's processing
- Zebra queries zaino made

**Options to explore:**

1. **Correlation IDs** - generate request ID at zaino gRPC edge, propagate through all log messages
   - Minimal: just logs with consistent request_id field
   - Allows grep-based debugging

2. **OpenTelemetry integration** - distributed tracing with spans
   - Industry standard
   - Visual trace waterfall
   - Higher implementation cost

3. **Structured logging baseline** - consistent JSON logs with request context
   - Foundation for either approach
   - Enables log aggregation queries

**Recommendation:** Start with correlation IDs in structured logs. Can upgrade to OTEL later if needed.

This needs design work - adding to zaino-design as open question.

## Files Changed

- `platform/kube-prometheus-stack/kustomization.yaml` - Helm chart with `includeCRDs: true`
- `platform/kube-prometheus-stack/values.yaml` - Custom config overlay
- `platform/kube-prometheus-stack/defaults.yaml` - Full defaults for reference
- `platform/loki-stack/kustomization.yaml` - Loki helm chart
- `platform/loki-stack/values.yaml` - Loki config with disabled sidecar
- `platform/defs/kube-prometheus-stack.yaml` - ArgoCD app definition
- `platform/defs/loki-stack.yaml` - ArgoCD app definition
- `bootstrap/get-grafana-password.sh` - Helper script

## Next Steps

1. **ServiceMonitor for Zebra** - get zebra metrics into Prometheus
2. **Custom dashboard** - unified view of zebra + zaino + (future) wallet metrics
3. **Design request tracing for zaino** - open question in zaino-design
4. **Sync speed dashboard** - historical analysis of sync performance across height ranges
