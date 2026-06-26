# Project Zeus — SAT analysis: UAT + dev↔uat comparison

Data: SAT **uat** cluster (`k8s-uat-sat.tigo.com.pa`, IPs `10.30.18.x`, ns `argocd`), 2026-06-22.
Read with `sat-dev-analysis.md` (dev). This doc records UAT and the deltas.

## Topology (uat)
- **43 business deployments** in ns `argocd`, all single replica, canaries `0/0`. Single ingress host
  `k8s-uat-sat.tigo.com.pa` (note `digital-sale-closure-frontend` also answers `mdwappst.tigo.com.pa`).
- **Same structure as dev**, with 2 fewer services: UAT is missing **`iuc-service-auth`** and **`eov-service-auth`**
  (both exist in dev). Worth confirming whether IUC auth is intentionally absent in uat.

## D3 — identical structural problems as dev
- **All 43 HPAs are `min=max=1`** → autoscaling disabled (same as dev).
- **13 services ≥100% of mem request** (OOM-risk band), vs 17 in dev — same root cause (256Mi request too small,
  peak `cr-service-config-sucursales` 127%, `cr-service-processpayments` 124%, `getpayments` 123%).
- **CPU again ~1% everywhere** — over-provisioned, memory-bound.
- **Every service has the same empty 10Gi RWX NFS PVC** — `/data` empty on uat too (confirmed pointless cross-env).
- ⚠️ **JVM config differs between envs:** uat `cr-service-getpayments` runs container-aware
  `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75 -XX:InitialRAMPercentage=50 -XX:+UseContainerSupport`,
  whereas dev uses the fixed `-Xmx512m`. **Env drift in the JVM memory model** — same image should behave the same.

## D2 — RabbitMQ: UAT is CLEAN (the dev bus is the messy one)
UAT rabbit is a single pod `rabbitmq-7477654cb9-jw9rk` (Deployment, not the 3-node StatefulSet dev has — infra drift).
- **vhost `/` is EMPTY** in uat (dev has orphaned NTT queues here with stuck messages).
- **vhost `/sat`**: all NTT queues have a consumer, **0 messages**, including `onDemandNttProcessQueue` (consumer on
  `/sat` — in **dev** its consumer is wrongly on `/`).
- **vhost `/int`**: all live queues have consumers, **0 messages**, and **both DLQs are 0/0** (dev has 3 stuck SMS +
  2 stuck email).
- `/tecrep` empty.

➡️ **The split-vhost bug and DLQ/backlog are DEV-ONLY.** UAT shows the *correct* wiring (everything on `/sat`,
nothing on `/`). This points at a **dev producer publishing to the wrong vhost (`/`)** — fix dev to match uat.

## D1 — Logging: same verdict, one cross-env defect confirmed
- **`consumer-sms` (uat):** identical **HikariCP "connection has been closed" WARN spam** every few seconds
  (11:46–11:51 sample). → The broken Postgres connection pool is **systemic, present in BOTH dev and uat**, not an
  env fluke. Strong candidate for a real defect ticket (DB/firewall closing idle conns < Hikari `maxLifetime`).
- **`getpayments` (uat):** tail showed only the **startup banner** (Spring Boot 3.5.0) + one Hibernate dialect WARN,
  then silence since 2026-06-03 — i.e. **no DEBUG health-probe spam** like dev produced. Suggests log level / probe
  logging differs between envs (another drift) OR no probe traffic logged. Still **no business logging** either way.
- `/data` empty → logs are not file-based (stdout), consistent with dev.

## Net dev↔uat comparison
| Aspect | DEV | UAT |
|---|---|---|
| Services | 45 | 43 (no `iuc-service-auth`, `eov-service-auth`) |
| HPA | all 1/1 (disabled) | all 1/1 (disabled) |
| OOM-risk (≥100% mem req) | 17 | 13 |
| PVC `/data` | empty, 10Gi RWX each | empty, 10Gi RWX each |
| JVM mem flags | `-Xmx512m` (fixed) | `MaxRAMPercentage=75` (container-aware) |
| RabbitMQ | 3-node STS; `/` orphans + stuck msgs + DLQ backlog 🔴 | 1-pod Deploy; clean, all on `/sat`, 0 backlog |
| HikariCP pool errors | yes 🔴 | yes 🔴 (systemic) |
| Ingress host | `k8s-dev-sat...` | `k8s-uat-sat...` (+`mdwappst` on DSC frontend) |

## Confirmed cross-cutting findings (both envs)
1. **Autoscaling disabled fleet-wide** (HPA pinned 1/1). 
2. **Memory requests undersized → OOM risk** on payment + notification services.
3. **CPU massively over-provisioned** (~1% of 100m).
4. **Every service mounts an unused 10Gi NFS PVC** → wasted storage + needless NFS failure dependency.
5. **HikariCP connection pool is broken** on DB-backed services (systemic).
6. **No business/structured logging, no correlation IDs** — logs not support-grade.

## Env-drift findings (dev ≠ uat — config should be identical)
- JVM memory flags differ (fixed `-Xmx` vs `MaxRAMPercentage`).
- RabbitMQ deployed differently (3-node STS in dev vs 1 pod in uat).
- Dev message bus misconfigured (wrong vhost) while uat is correct.
- Service set differs (iuc/eov auth).
