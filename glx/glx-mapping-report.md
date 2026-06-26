# Galaxion (GLX) + SAT — Platform Standardization Report

**Clusters:** GLX `tocpait-glx-sit` (SIT) · `tocpait-glx-uat` (UAT) · `tocpait-glx` (Master/PROD) · SAT `tocpait-sat-dev` (dev) — Tigo Panamá
**Collected:** 2026-06-23 (GLX) / 2026-06-22 (SAT dev) — read-only.

## Objective

Map the current state of the four environments **and** define a **single common setup standard** to converge Galaxion (SIT/UAT/PROD) and SAT toward. For each dimension this report states **what is wrong, in which environment, and the desired configuration** — so the gap and the action are explicit, not just the inventory.

> The goal is one standard across GLX and SAT (the client wants the environments harmonized, not treated as separate worlds). SAT runs a different application set (cr-* / iuc-* / adminntt-*), but the **same platform rules** apply to it (§5).

---

## 0. Executive summary — what to fix

| # | Issue | Environment | Action (target) | Severity |
|---|---|---|---|---|
| 1 | **Image pulls failing — registry TLS untrusted** (`x509: certificate signed by unknown authority`) → 14 frozen rollouts/migrations | **Galaxion PROD** (`tocpait-glx`) | Restore CA trust for `glx-registry.tigo.com.pa` on the nodes; alert on `ImagePullBackOff` | 🔴 **Critical** |
| 2 | **`maildev` pulled from public Docker Hub** | UAT + **PROD** | Mirror to internal registry or remove from prod | 🟠 High |
| 3 | **`-SNAPSHOT` images in production** | PROD | Ban mutable/SNAPSHOT tags in UAT/PROD; promote immutable releases | 🟠 High |
| 4 | **No autoscaling / no HA** (1 replica everywhere) | All 4 | HPA for stateless APIs, KEDA for queue consumers, `minReplicas ≥ 2` | 🟠 High |
| 5 | **Istio installed but unused** | GLX SIT | Pick one mesh standard for all envs (remove from SIT, or adopt everywhere) | 🟡 Medium |
| 6 | **Registry coupling** (UAT pulls from SIT registry) | SIT + UAT | Per-env registry or a clear promotion pipeline | 🟡 Medium |
| 7 | **Observability inconsistent** (Prom off in SIT; PROD logging unknown) | SIT + PROD | Common Prometheus+Grafana + unified logging across GLX/SAT | 🟡 Medium |
| 8 | **Workloads in `argocd` namespace** | SAT | Dedicated application namespace | 🟡 Medium |
| 9 | **Ingress host typos** (`.cam`, wrong-env host) | All | Correct hosts to `*.tigo.com.pa` | 🟢 Low |
| 10 | **SIT CPU over-request** (500m vs 150m) | SIT | Right-size to the UAT/PROD profile | 🟢 Low |
| 11 | **App-set drift** between environments | SIT/UAT/PROD | Reconcile the component set per env | 🟢 Low |

---

## 1. Platform comparison (current state)

| Dimension | GLX **SIT** | GLX **UAT** | GLX **PROD** | **SAT dev** |
|---|---|---|---|---|
| Cluster | `tocpait-glx-sit` | `tocpait-glx-uat` | `tocpait-glx` | `tocpait-sat-dev` |
| K8s distro | RKE2 v1.33.0+rke2r1 | RKE2 v1.33.0+rke2r1 | RKE2 **v1.33.5+rke2r1** | RKE2 **v1.32.8+rke2r1** — ⚠️ node skew (1.28.15 / 1.32.8 / 1.34.1) |
| Topology | 3 mstr + 6 wrk + 2 spark (11) | 3 mstr + 10 wrk + 2 spark (15) | 3 mstr + **22 wrk (z1/z2)** + 2 spark (27) | 3 mstr + dedicated pools: 2 NFS, 3 RabbitMQ, 1 SLB, 1 jobs, 4 ws-node (~14); 2 nodes cordoned |
| App namespace | `glx` (~78) | `glx` (~77) | `glx` (~77) | **`argocd`** (shared — anti-pattern), 45 |
| App portfolio | Galaxion | Galaxion | Galaxion | NTT/satellite (cr-*/iuc-*/adminntt-*) |
| Istio | Installed 1.26.1, sidecar 2/2, **no mesh CRs** | Not installed | Not installed | Not installed |
| Kiali | Absent | Absent | Absent | Absent |
| Autoscaling | only `istiod` HPA | **none** | **none** | **45 HPAs, all `min=max=1`** |
| Replicas | 1 | 1 | 1 | 1 (canaries 0/0) |
| Prometheus/Grafana | **Disabled (0/0)** | Running | Running | no Prometheus; Grafana (Loki) |
| Logging | none observed | `logging` ns (fluent-bit) | **none observed** | Loki + Promtail + Grafana |
| Registry | `glx-registry-sit` | `glx-registry-sit` (shared) | `glx-registry` (own) | `registry-local` |
| Ingress | nginx `glx-<app>-sit…` (10.30.15.x) | nginx `glx-<app>-uat…` (10.30.19.x) | nginx `glx-<app>…` (10.30.14.x) | nginx single host `k8s-dev-sat…` |

---

## 2. Current vs desired — the common standard

For each dimension: **what's wrong → where → the desired (standard) configuration.** Config snippets show the *target*, not full manifests.

### 2.1 Autoscaling & resiliency — *the essential point*

> This is about **autoscaling**, which is distinct from the pod resource config in §2.2. Today nothing scales and nothing is highly available.

| What's wrong | Where | Desired standard |
|---|---|---|
| No HPA at all → cannot scale | GLX SIT/UAT/PROD | Real HPA on stateless services |
| 45 HPAs but `min=max=1` (decorative) | SAT dev | Replace with real min/max or KEDA |
| Single replica → single point of failure | All 4 | `minReplicas ≥ 2` (HA baseline) |
| Queue consumers/ETL never scale on load | GLX connectors, SAT consumers | **KEDA** on queue depth |

**Desired — stateless API/service (HPA):**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 2          # HA baseline — today: 1
  maxReplicas: 6
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 65 } }
```

**Desired — event-driven consumer (KEDA on RabbitMQ):** for SAT `adminntt` consumers (email/sms/notification/ondemand) and GLX payment/mediation/workflow connectors.
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  minReplicaCount: 1
  maxReplicaCount: 10
  triggers:
    - type: rabbitmq
      metadata: { queueName: mail_queue, mode: QueueLength, value: "20" }
```

### 2.2 Pod resources (right-sizing)

> This is the **pod configuration** (requests/limits) — review noted it was being shown *instead of* autoscaling. Both matter; keep them separate.

| What's wrong | Where | Desired standard |
|---|---|---|
| CPU over-requested (core/backend 500m, ~98% idle) | GLX **SIT** | Align to UAT/PROD profile (≈150m) |
| CPU over-requested (100m × 45 = 4.5 cores, ~76m used) | SAT | Request 25–50m where idle |
| Memory undersized: req 256Mi / limit 512Mi, JVM `-Xmx512m` == limit → OOM risk on 17 svcs | SAT | req 384Mi, limit 768Mi, `-Xmx` ≈ 70% of limit |
| `maildev` has no requests/limits (BestEffort) | UAT/PROD | Set minimal requests/limits |

**Desired — Java service:**
```yaml
resources:
  requests: { cpu: 50m,  memory: 384Mi }   # SAT today: 100m / 256Mi
  limits:   { cpu: 500m, memory: 768Mi }   # SAT today: ...  / 512Mi
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-Xmx512m"   # ≈70% of the 768Mi limit (today -Xmx512m == limit → no headroom)
```

### 2.3 Service mesh (Istio)

| What's wrong | Where | Desired standard |
|---|---|---|
| Istio installed, sidecar on every pod, but zero mesh CRs, mTLS permissive, no Kiali → cost, no benefit | GLX SIT only | **One standard for all envs** |

Pick one and apply to all four environments:
- **Option A (recommended, low effort):** remove the unused injection from SIT → parity with UAT/PROD/SAT (no mesh).
- **Option B (higher value):** adopt Istio everywhere with **mTLS STRICT + Kiali + baseline policies**.

The current half-state (mesh in one env, doing nothing) is the one outcome to avoid.

### 2.4 Registry & images

| What's wrong | Where | Desired standard |
|---|---|---|
| New image pulls fail — registry **TLS cert untrusted** (x509), see §3 | PROD | Restore registry CA trust on nodes; alert on `ImagePullBackOff` |
| `maildev` from public Docker Hub | UAT + PROD | Mirror internally or remove from prod |
| `-SNAPSHOT` (mutable) tags in production | PROD (`customer-pa-management`, `tigo-pa-adjustment-custom-service`) | Immutable release tags only; **ban `*-SNAPSHOT` in UAT/PROD** |
| UAT pulls from the **SIT** registry | SIT + UAT | Per-env registry or explicit promotion pipeline |
| PROD ahead of lower envs (`geographic-management`, `tigo-ar-workflow-connector`) | mixed | Enforce SIT → UAT → PROD promotion direction |

### 2.5 Observability

| What's wrong | Where | Desired standard |
|---|---|---|
| Prometheus/Grafana scaled to 0/0 | GLX SIT | Prometheus + Grafana **on** in every env |
| No `logging` namespace observed | GLX PROD | Confirm + standardize log shipping |
| Three different logging approaches (none / fluent-bit→ES / Loki) | GLX vs SAT | **One unified logging stack** across GLX + SAT |

### 2.6 Namespace isolation & ingress hygiene

| What's wrong | Where | Desired standard |
|---|---|---|
| Workloads share the `argocd` namespace (no blast-radius isolation) | SAT | Dedicated application namespace |
| Ingress TLD typo `.cam` | all (`...tasks-pa-stg.tigo.cam`, `glx-users-management.tigo.cam`) | `*.tigo.com.pa` |
| UAT ingress points at a `sit` host | UAT (`glx-users-management-sit.tigo.cam`) | Correct to the UAT host |
| Resource name typo `equipments-seravice-ingress` | all | Rename |

---

## 3. 🔴 Incident — Galaxion PROD (`tocpait-glx`): image pulls failing on registry TLS trust

**Environment:** Galaxion **PRODUCTION** cluster `tocpait-glx`, namespace `glx`, registry `glx-registry.tigo.com.pa`. Onset ~2026-06-18 (errors aged ~5d on 2026-06-23). **14 pods** affected.

**Root cause (confirmed via `kubectl describe`):** the nodes cannot verify the TLS certificate of the production registry —
`tls: failed to verify certificate: x509: certificate signed by unknown authority`.
So **every new image pull from `glx-registry.tigo.com.pa` fails**. This is a **registry CA / certificate-trust problem — not missing images.** The images exist; the nodes simply no longer trust the registry's certificate (most likely the cert was renewed/rotated without distributing the issuing CA to the nodes / containerd registry config).

**Evidence (verbatim from the cluster):**
```
Failed to pull image "glx-registry.tigo.com.pa/glx/itsf-team/itsf-dbmdl:1.1.0-SNAPSHOT":
  Head "https://glx-registry.tigo.com.pa/v2/glx/itsf-team/itsf-dbmdl/manifests/1.1.0-SNAPSHOT":
  tls: failed to verify certificate: x509: certificate signed by unknown authority

Failed to pull image "glx-registry.tigo.com.pa/galaxion-docker/core/backend/collections-service:8.1.2":
  ... tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Mechanism:** already-running pods keep serving because their image is **cached on the node**; only **new** pods need to pull. So the wave hits (a) one-shot DB-migration helpers `*-dbmdl` and (b) new ReplicaSets — while the Deployment still shows the **old** RS at `1/1`, masking a rollout that silently never completes. Note `account-receivable-facade` (6.4.0) and `payments-ui` (1.5.3) fail on the **same tag** already running — confirming it is the pull/TLS path, not the image version.

**Affected (14):**

| Pod | Image | Status / error |
|---|---|---|
| `itsf-dbmdl-*` | `…/glx/itsf-team/itsf-dbmdl:1.1.0-SNAPSHOT` | ImagePullBackOff — **x509 unknown authority** |
| `collections-service-dbmdl-8.1.2-*` | `…/core/backend/collections-service:8.1.2` | ImagePullBackOff — **x509 unknown authority** |
| `account-receivable-facade-*` (new RS) | `…/core/backend/account-receivable-facade:6.4.0` | ImagePullBackOff (old RS 6.4.0 still 1/1) |
| `payments-ui-*` (new RS) | `…/core/frontend/payments-ui:1.5.3` | ErrImagePull (old RS still 1/1) |
| `cdr-usage-consumption-service-*` | `…/eirie/backend/cdr-usage-consumption-service:2.0.4` | ImagePullBackOff, 138 restarts |
| `sms-sender-service-*` (new RS) | `…/core/backend/sms-sender-service` | ImagePullBackOff (old RS still 1/1) |
| + 8 `*-dbmdl` helpers (add-ons, addresses, appointments, customer-history, discounts, order-status, otp-verification, security-questions) | various `…:<version>` | ImagePullBackOff — x509 |

All failures are on the **same registry host** `glx-registry.tigo.com.pa` with the **same x509 error**.

**Action:** (1) **restore CA trust for `glx-registry.tigo.com.pa` on the nodes** — add the registry's CA to RKE2/containerd (`/etc/rancher/rke2/registries.yaml`) or the OS trust store, or reissue the registry certificate with a chain the nodes already trust; (2) verify pulls recover (new pods schedule); (3) **alert on `ImagePullBackOff`** so a cert/registry change cannot silently freeze production rollouts for days again.

---

## 4. Per-application mapping — GLX (apps under our responsibility)

Constant today (all GLX envs): replica = 1, no HPA (target state in §2.1). SIT adds an istio-proxy sidecar (2/2).

### 4.1 Presence & image tags (SIT × UAT × PROD)

Registry: SIT/UAT = `glx-registry-sit.tigo.com.pa`, PROD = `glx-registry.tigo.com.pa`.

| App | SIT | UAT | PROD | Note |
|---|---|---|---|---|
| acquisition-prospects-service | 5.1.1 | 5.1.1 | 4.5.4 | |
| adjustments-service | 8.1.0 | 8.1.0 | 7.3.0 | |
| barrings-service | 4.3.2 | 4.3.2 | 4.3.2 | aligned |
| billing-service | 2.4.0 | 2.4.0 | 2.2.0 | |
| case-management-pa-audit-worker | release-4.3.0 | release-4.3.0 | release-4.3.0 | ⚠️ worker exposed via ingress |
| case-management-pa-users-worker | release-4.0.1 | release-4.0.1 | release-4.0.1 | ⚠️ worker exposed via ingress |
| collections-service | 8.1.8 | 8.1.2 | 7.3.3 | promo stuck in PROD (§3) |
| customer-pa-management | release-1.0.0 | release-1.0.0 | **1.0.0-SNAPSHOT** | ⚠️ SNAPSHOT in prod |
| email-sender-service | 3.4.0 | 3.4.0 | 3.2.0 | |
| geographic-management | 1.0.1-SNAPSHOT | 1.0.1-SNAPSHOT | **1.0.3** | ⚠️ prod ahead + SNAPSHOT below |
| maildev | absent | maildev/maildev | maildev/maildev | ⚠️ public Docker Hub |
| otp-verification-service | 6.1.0 | 6.1.0 | 5.3.0 | |
| prospect-lead | 2.0.0 | release-1.1.0 | 1.1.0 | ⚠️ tag scheme differs |
| sms-sender-service | 3.3.0 | 3.3.0 | 3.3.0 | aligned; new RS stuck (§3) |
| tigo-ar-workflow-connector | 1.0.0 | 1.0.0 | **1.0.1** | ⚠️ prod newer |
| tigo-collection-management-workflow-connector | absent | 1.0.0-SNAPSHOT | absent | only in UAT |
| tigo-equipments-workflow-connector | 1.12.0 | 1.10.1 | 1.8.1 | |
| tigo-pa-adjustment-custom-service | 1.0.0-SNAPSHOT | release-3.1.24 | 1.0.0-SNAPSHOT | ⚠️ 3-way inconsistent |
| tigo-pa-order-processor | 1.2.0 | 1.2.0 | 1.1.0 | |
| user-management-workflow-connector | absent | 2.0.1 | 2.0.1 | missing in SIT |
| workflow-engine-facade | 3.1.0 | 2.3.0 | 2.1.0 | |

### 4.2 Resources (SIT vs UAT=PROD)

UAT and PROD share identical sizing; SIT is the outlier (over-requests CPU on core/backend). Full per-app figures retained from collection; the standardization target is in §2.2.

| Profile | SIT | UAT = PROD |
|---|---|---|
| core/backend (e.g. acquisition, email-sender, sms-sender) | 500m/1 · 1Gi/2Gi | 150m/1 · 768Mi/2Gi |
| PA/custom (e.g. otp, geographic, ar-connector) | 50m/500m · 256Mi/1Gi | 150m/500m · 768Mi/1Gi |
| guaranteed (billing-service, workflow-engine-facade) | req == limit | req == limit |

---

## 5. SAT under the common standard

SAT dev is a different application portfolio (POS/cash `cr-*`, IUC/SAP `iuc-*`, NTT admin/ETL `adminntt-*`, `digital-sale-closure`), **but the same standard applies**. Today it diverges on every axis:

| Standard (§2) | SAT current | Target |
|---|---|---|
| Autoscaling | 45 decorative HPAs (`min=max=1`) | HPA (stateless) + KEDA (the adminntt/payment consumers); `minReplicas ≥ 2` |
| Resources | CPU 100m (~98% idle), mem 256/512 + `-Xmx512m`==limit (OOM on 17 svcs) | right-size per §2.2 |
| Namespace | workloads in `argocd` ns | dedicated namespace |
| Registry/images | base images from `registry-local` | same promotion/immutability rules |
| Observability | Loki only | unified stack with GLX |

**SAT-specific items to converge:**
- **Node version skew** — the cluster mixes RKE2/K8s versions across nodes (`v1.28.15`, `v1.32.8`, `v1.34.1`) with the control plane on `v1.32.8`, and **2 nodes cordoned** (`SchedulingDisabled`: `nfs-01` on the old 1.28.15, `wsnode-04` on 1.34.1). GLX clusters are uniform per env (1.33.0 / 1.33.5). → align node versions; drain/replace the stragglers.
- **Empty NFS PVCs** — all 45 services mount a 10Gi RWX NFS PVC that is **unused** (~450 GiB allocated for nothing) and a hard NFS dependency for no benefit → remove from base overlay.
- **RabbitMQ split-vhost misconfig** (`/` vs `/sat`) leaves create/close NTT messages stuck with no consumer; **DLQ/backlog with no drainer** (3 dead SMS, 2 stuck emails).
- **Logging not support-grade** — effective DEBUG despite `LOG_LEVEL=INFO`, ~100% `/health` probe noise, no correlation IDs, no JSON.
- Duplicated auth (one auth service per domain).

> Detail: `sat-dev-analysis.md`, `sat-observability-logging-report.md`, `sat-dev-observability-plan.md`.

---

## 6. Action plan (prioritized)

1. **🔴 Critical — PROD registry TLS trust (§3):** restore the CA for `glx-registry.tigo.com.pa` on the nodes (RKE2/containerd or OS trust store) so the 14 frozen rollouts/migrations recover; add an `ImagePullBackOff` alert.
2. **🟠 High — image governance:** remove/mirror `maildev`; ban `-SNAPSHOT` and public refs in UAT/PROD; enforce SIT→UAT→PROD promotion.
3. **🟠 High — autoscaling & HA (§2.1):** introduce HPA (stateless) + KEDA (consumers), `minReplicas ≥ 2`; replace SAT's decorative HPAs.
4. **🟡 Medium — mesh decision (§2.3):** choose one Istio standard for all envs.
5. **🟡 Medium — registry decoupling (§2.4)** and **observability parity (§2.5)** (Prometheus on in SIT; confirm PROD logging; unify GLX+SAT).
6. **🟡 Medium — SAT namespace** out of `argocd`; remove empty NFS PVCs; fix RabbitMQ split-vhost + DLQ drainer.
7. **🟢 Low — right-size SIT CPU (§2.2)**, fix ingress typos (§2.6), reconcile app-set drift.

*Internal collection runbook: see `glx-collection-runbook.md` (not part of this report).*
