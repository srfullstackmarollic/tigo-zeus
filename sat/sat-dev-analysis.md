# Project Zeus — SAT analysis (working doc)

Data sources: GitOps `tigo-devops-panama/apps/overlays/satelite` (static) + SAT **dev** cluster
(`tocpait-sat-dev`, namespace `argocd`), collected 2026-06-22. UAT pending.

## Topology (dev)
- **45 business deployments** in namespace **`argocd`** (workloads share the ArgoCD namespace — anti-pattern, no blast-radius isolation).
- All **single replica** (`1/1`); canary deployments exist but scaled to `0/0` (idle).
- All exposed through **one ingress host** `k8s-dev-sat.tigo.com.pa` (path-based), ClusterIP svc :80.
- Service families:
  - **cr-*** (Cash Register / POS): app-backend, app-frontend, auth, cash, cancel-payment, config-cajas, config-metodos-pago, config-sucursales, getcashregisteramount, getcustomerdebt, getpayments, processpayments
  - **iuc-*** (IUC billing / SAP): app-backend, app-frontend, auth, checkdata, elt-service-processdata, exporttofile, get-auxiliar, get-summary, processsap
  - **adminntt-*** (NTT admin / notifications / ETL): app-frontend, auth, master-catalogs, dashboard-nttfilters, get-search-ntt, nttdetails, nttreports, searchmonthntt, notificationondemand, notification-consumer, ondemand-consumer, consumer-email, consumer-sms, etl-logs, etl-archivos-hfc-ftth, etl-direcciones-tytan, etl-procesos-glx, etl-procesos-tytan, notification-templates
  - **digital-sale-closure** (+ internal-* + eov-service-auth)
- Each domain ships its **own auth service** (cr-service-auth, iuc-service-auth, adminntt-service-auth, eov-service-auth) — duplicated auth.

## D3 — Horizontal scalability (HEADLINE FINDINGS)

### 1. Autoscaling is declared but DISABLED everywhere
Every HPA is `minReplicas = maxReplicas = 1`. The HPAs exist (45 of them) but cannot scale.
They are decorative. CPU/mem targets (70%/75%) are set but unreachable as scaling triggers.

### 2. Memory requests are undersized → OOM risk on 17 services
HPA "memory %" is computed against the **request (256Mi)**. 17 Java services run **≥100% of request**
(peak 124% ≈ 319Mi), and the JVM is configured `-Xmx512m` with container **limit 512Mi** — heap ceiling
== container limit, so **zero headroom** for metaspace/threads/off-heap → OOMKill risk under load.

OOM-risk services (≥100% of mem request): adminntt-service-consumer-email (113%), consumer-sms (109%),
dashboard-nttfilters (123%), notification-consumer (101%), searchmonthntt (116%); cr-service-cancel-payment (123%),
cash (101%), config-cajas (100%), config-sucursales (121%), getcashregisteramount (102%), getcustomerdebt (116%),
getpayments (124%), processpayments (117%); iuc-app-backend (106%), checkdata (107%), exporttofile (118%), processsap (120%).
(+ ~12 more in the 89–99% "near" band.)

### 3. CPU is massively over-requested
45 pods × `100m` request = **4500m (4.5 cores) reserved**; **actual total usage = 76m (~0.08 cores)**.
~98% of reserved CPU sits idle → wastes schedulable capacity, hurts bin-packing.

### 4. Right-sizing direction (pre-KEDA)
- **CPU request** 100m → ~25–50m (keep limit modest). Frees ~4 cores cluster-wide.
- **Memory request** 256Mi → ~384Mi; **limit** 512Mi → 768Mi; fix JVM `-Xmx` to ~70% of limit (e.g. `-Xmx512m` with 768Mi limit) so heap ≠ limit.
- Frontends (nginx, ~5–12Mi) are fine; only need a tiny mem request.

### 5. Which services are real HPA/KEDA candidates
- **CPU-bound HPA: almost none** — CPU is ~1–2% everywhere; CPU is not the scaling signal here.
- **KEDA (event-driven) candidates** = the RabbitMQ consumers: `adminntt-service-consumer-email`,
  `consumer-sms`, `notification-consumer`, `ondemand-consumer` (scale on queue length). **Pending queue data.**
- **Batch/ETL** (`*-etl-*`, `iuc-elt-service-processdata`, `iuc-service-processsap`) — candidates for KEDA
  cron/queue scalers or Jobs, not always-on HPA.
- **Stateless query APIs** (cr getpayments/getcustomerdebt/etc.) could scale on RPS/latency, but need request-volume data (no ingress/RPS metrics yet).

## D3 caveat — PVCs are mounted but EMPTY (confirmed)
`ls /data` on `cr-service-getpayments` → **empty** (just `.`/`..`). So every one of the 45 services mounts a
**10Gi RWX NFS PVC that is unused**:
- ~**450 GiB of NFS** allocated for nothing across SAT dev.
- Every pod has a hard **NFS mount dependency** for no benefit → if NFS hiccups (and it has — see NFS incidents),
  pods that need nothing from disk still fail to start/stay up.
- **Action:** remove the PVC + volumeMount from the base overlay for services that don't use `/data`.

## D1 — Logging: captured, but NOT support-grade (confirmed on cr-service-getpayments)
Logs **do go to stdout** (kubectl logs works → collected by k8s). But the content is unusable for support:
1. **Effective level is DEBUG, not INFO.** Despite `LOG_LEVEL=INFO` in the manifest, the app emits Spring
   framework `DEBUG` (DispatcherServlet, RequestMappingHandlerMapping, HttpEntityMethodProcessor).
   → **`LOG_LEVEL` env is not wired into the logging config.**
2. **~100% health-check noise.** Readiness/liveness probe both hit `/health` (every 10s/30s) and each request
   emits ~5 DEBUG lines. A *payment* service's logs are entirely health pings — zero business events visible.
3. **No correlation/trace IDs, no JSON/structured format**, no business context (txn id, account, amount, result).
4. **Broken metadata:** `/health` returns `Version: unknown | Environment: dev (unset)` — the overlay's
   `APP_ENVIRONMENT`/version are **not reaching the app** (config injection partial/broken).

**D1 verdict (this service):** present + collected, but **insufficient for post-prod support** — wrong level,
drowned by probe noise, no correlation IDs, no business logging, no structure. Need to confirm this pattern
holds across the other domains (consumers, ETL).

## D2 — RabbitMQ (COMPLETE for dev)
RabbitMQ runs in `argocd` ns (`rabbitmq-0/1/2`, 3-node, Running 47d). Vhosts: `/`, `/sat`, `/int`, `/tecrep`.
Format below: queue — messages / consumers.

### vhost `/` (LEGACY / orphaned — most queues have NO consumer)
- `onDemandNttProcessQueue` — 0 / **1**  ← only consumer here
- `mail_queue` 0/0 · `sms_queue` 0/0 · `updateNttProcessQueue` 0/0 · `ntt.notification.create.delay.queue` 0/0 · `ntt.notification.close.delay.queue` 0/0
- `createNttProcessQueue` — **1 / 0**  ← message stuck, no consumer
- `closeNttProcessQueue` — **1 / 0**  ← message stuck, no consumer

### vhost `/sat` (where the NTT consumers actually listen)
- `mail_queue` 0/**1** · `sms_queue` 0/**1** · `updateNttProcessQueue` 0/**1** · `createNttProcessQueue` 0/**1** · `closeNttProcessQueue` 0/**1**
- `onDemandNttProcessQueue` — 0 / **0**  ← no consumer here (its consumer is on `/`)
- `ntt.notification.*.delay.queue` 0/0 (delay/retry)

### vhost `/int` (integrations bus — payments + notifications)
- `paymentProcessQueue` — 0 / **1**  ← payments
- `mediationSyncQueue` — 0 / **1**
- `pa.integrations.notification.email` 0/1 · `pa.integrations.notification.sms-adminntt` 0/1 · `...sms-collections` 0/1 · `...sms-default` 0/1
- `pa.collections.manual-step.notification` — 0 / 0
- `pa.email.events` — **2 / 0**  ← emails backing up, no consumer
- `pa.integrations.notification.email.dlq` — 0 / 0  · `pa.integrations.notification.sms.dlq` — **3 / 0**  ← 3 failed SMS in DLQ

### vhost `/tecrep` — no queues (empty).

### 🔴 D2 misconfiguration #1 — split-vhost on the NTT bus
The NTT process consumers listen on **`/sat`**, but something is **publishing the same queues to `/`** →
`createNttProcessQueue` and `closeNttProcessQueue` on `/` each hold a stuck message with **no consumer**.
Meanwhile `onDemandNttProcessQueue`'s consumer is on `/` (not `/sat`). The producers/consumers disagree on which
vhost to use. **Messages published to `/` for create/close NTT will never be processed.**

### 🔴 D2 reliability #2 — DLQ + backlog with no drainer
`pa.integrations.notification.sms.dlq` = **3 dead SMS** and `pa.email.events` = **2 stuck**, both with **0 consumers**
→ failures are accumulating silently with nothing reading the dead-letter / event queues.

### D3 — KEDA candidates (event-driven, confirmed by consumer attachment)
| service | queue(s) it drains | scaler |
|---|---|---|
| adminntt-service-consumer-email | `/sat:mail_queue`, `/int:...notification.email` | RabbitMQ queue length |
| adminntt-service-consumer-sms | `/sat:sms_queue`, `/int:...sms-adminntt/-collections/-default` | RabbitMQ queue length |
| adminntt-service-notification-consumer | `/sat:create/close/updateNttProcessQueue` | RabbitMQ queue length |
| adminntt-service-ondemand-consumer | `/:onDemandNttProcessQueue` | RabbitMQ queue length |
| (cr-service-processpayments?) | `/int:paymentProcessQueue` | RabbitMQ queue length — confirm owner |
| (mediation consumer) | `/int:mediationSyncQueue` | RabbitMQ queue length |
Note: dev traffic ≈ 0, so depths can't set thresholds here — KEDA *eligibility* is established; thresholds tune on prod load.

## D1 — second sample (adminntt-service-consumer-sms): different noise, same verdict
The entire log tail is **HikariCP connection-pool WARN spam**:
`HikariPool-1 - Failed to validate connection ... This connection has been closed. Possibly consider using a shorter maxLifetime`
— repeating every 1–4 s plus bursts from `scheduling-1`.
- **Reliability defect:** the Postgres pool is constantly finding dead connections — DB/firewall is closing idle
  connections faster than Hikari's `maxLifetime`. The consumer may not be reliably processing.
- **Logging:** again **no business events** (no "received msg → sent SMS → result"); 100% infra WARN noise.

**D1 pattern across both samples:** logs are captured to stdout but **not support-grade** — either DEBUG/probe noise
(query svc) or infra WARN spam (consumer), never business context, never correlation IDs, never structured.

## Cross-cutting reliability finding
`maxLifetime` / idle-connection handling is misconfigured against the Postgres tier (firewall or DB closing idle
conns). Likely affects all DB-backed Java services, not just consumer-sms. Worth a dedicated check.

## Open data still needed
1. **RabbitMQ** consumers column + `/sat` `/int` `/tecrep` queues — finish D2 async edges + D3 KEDA inputs.
2. **Same 6-command collection on UAT.**
3. (optional) a few more log samples (cr-app-backend, iuc-service-processsap) to confirm D1 pattern domain-wide.
