# Project Zeus — Application Logging (SAT)

Goal: verify the **SAT (Satélite)** microservices are good enough to support in production.
**Scope of this phase:** SAT only, **dev + uat** environments.

## Deliverables
1. **D1** — list of microservices with logging sufficient for post-prod support
2. **D2** — functioning map: who consumes what, through what (HTTP / RabbitMQ / DB)
3. **D3** — horizontally-scalable services → inputs for **HPA + KEDA**
4. **D4** — diagrams for the highest-criticality use cases

## Source of truth
- Static layer: GitOps repo `tigo-devops-panama/apps/overlays/satelite` (18 deploys + 2 cronjobs + 1 tool)
- Runtime layer: dev + uat clusters, collected from the Wallix bastions (no direct access from here)

## How to collect runtime data
On each bastion (dev and uat are separate hosts), with kubectl already pointed at the cluster:

```bash
# paste scripts/zeus-sat-collect.sh once (or scp it), then:
ENV=dev bash zeus-sat-collect.sh   # on the dev bastion
ENV=uat bash zeus-sat-collect.sh   # on the uat bastion
```

Output is written to `/tmp/zeus-sat-<env>-<timestamp>.txt` (and echoed). Send it back for analysis.

## Repository layout
```
zeus/
├── README.md
├── sat/        # workstream SAT: análises, planos, runbook, informes (.md)
├── glx/        # workstream GLX: mapping, master, runbook, configs (.md + .txt)
├── scripts/    # coletores p/ rodar nos bastions (zeus-*.sh)
├── reports/    # entregáveis renderizados (.pdf) + fontes (.html)
└── data/       # dumps brutos de coleta (outs-cmd, *-out, zeus_out)
```

Key SAT docs: `sat/sat-dev-analysis.md`, `sat/plan-observabilidad-istio-kiali-sat-dev.md`
(+ `sat/sat-dev-istio-kiali-plan.md` detalhado), `sat/sat-dev-istio-kiali-runbook.md`
(execução Istio+Kiali no bastion). Pre-flight: `scripts/zeus-sat-istio-preflight.sh`.

## Static findings so far (from GitOps)
- **HPAs are no-ops**: every service has `minReplicas=maxReplicas=1` (autoscaling declared but disabled).
  Only `digital-sale-closure-services` is `1-3`.
- **Uniform sizing**: every service `100m/256Mi → 300m/512Mi` (copy-paste defaults, not tuned).
- **Logging**: only `LOG_LEVEL=INFO` env var; no structured/JSON/correlation-ID config in manifests.
  Actual log quality must be judged at runtime (batch 2).
- **All services mount a PVC at `/data`** → relevant to D3 (PVC-bound singletons don't scale cleanly).
- **RabbitMQ central** (vhosts incl. /sat /int /tecrep) → prime KEDA queue-length scaler candidates.
