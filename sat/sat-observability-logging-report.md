# SAT — Application Logging & Observability Assessment

**Project:** Tigo Panamá — Zeus
**Scope:** SAT cluster (starting with **dev**), application logs first; service mesh (Istio + Kiali) and Kibana as later phases.
**Reference cluster:** GLX (UAT) — used to see what is already in place and what is reusable.
**Status:** Assessment / proposal. **Nothing has been applied to any cluster.**
**Date:** 2026-06-23

---

## 1. Executive summary

- **Neither SAT nor GLX has a service mesh.** No **Istio** and no **Kiali** in either cluster. A mesh on SAT is a **greenfield install**, not "copy GLX".
- **SAT and GLX are fully isolated clusters** (no network path). GLX's external ELK **cannot** be reused by SAT — SAT needs its **own** log backend.
- **All application logs are plain text — zero JSON anywhere.** Collection works (SAT: Promtail→Loki; GLX: fluent-bit→external ELK), but logs are **not support-grade**: effective DEBUG, dominated by health-probe noise, no consistent structure.
- **The logging behaviour is centralized in shared base images** (`tigo-spring-base`, `tigo-python-base`, `tigo-php-base`). This is the key finding: **logging can be standardized at the base-image layer — one change, inherited by all apps on rebuild — without editing any application's source code.** The Spring base (`sit-1.1.0`) **already implements a `CorrelationIdFilter`** (generates/propagates a correlation_id).
- **Constraint honored:** we will **not change application code**. Two complementary, code-free tracks are proposed:
  - **L1 — Pipeline (zero rebuild):** normalize at capture in **fluent-bit** (per-format parsers, multiline stack-trace joins, drop probe noise, per-namespace index).
  - **L2 — Base image (rebuild, no app-source change):** bump the `tigo-*-base` images to emit **JSON**, default to **INFO**, exclude `/health` from logs, and ensure the correlation filter is everywhere. Apps inherit it on their next CI rebuild.
- **Decided:** SAT log backend = its **own Elastic + Kibana, in-cluster via the ECK operator**; logs and the Istio/Kiali plan run **in parallel**, logs first.

---

## 2. Method

Read-only collection from both clusters via the bastion (rke2 kubeconfig at `/etc/rancher/rke2/rke2.yaml`). Captured: cluster/namespace/workload inventory, mesh & CRD presence, the logging stacks, GLX fluent-bit config, and a **per-application log-format survey** on SAT dev (20 representative apps across Java/Spring, Python, PHP, nginx, consumers). No changes were applied.

---

## 3. Current state — SAT dev

### 3.1 Workloads
- ~30+ business apps in the **`argocd`** namespace (anti-pattern: workloads share the ArgoCD + RabbitMQ namespace — no blast-radius isolation).
- Naming: Deployment `…-v1`, Service `…-v1-services`, container `app-container-…-v1`. **Single container per pod, no sidecars.**

### 3.2 Service mesh
- **None.** No `istio-system`, no `istio.io` CRDs, no `istio-injection` namespaces, no Kiali, no `istio-proxy` sidecars.

### 3.3 Logging stack
- Namespace **`observability`**: **Loki + Grafana + Promtail** (DaemonSet, all 13 nodes). Promtail already scrapes **all pod stdout → Loki**. **Collection is not the problem; quality is.**
- **No Elasticsearch / Kibana anywhere in SAT.**

---

## 4. Current state — GLX UAT (reference)

- **Service mesh: none** (same as SAT). If a mesh exists at all, it would be GLX **prod** — to confirm.
- **Logging — the reusable pattern:** namespace **`logging`** with a **fluent-bit DaemonSet** (13 nodes, image `registry-local.tigo.com.pa/fluent-bit:3.1.4`) → **external Elasticsearch** (secret `elasticsearch-credentials`). Confirmed config:
  - **Input:** `tail /var/log/containers/*.log`, `Parser cri` (containerd/rke2), offset DB, `Mem_Buf_Limit 10MB`.
  - **Filter:** standard `kubernetes` (pod/namespace metadata) + **Lua namespace allow-list** — only `cdr-pa`, `glx`, `argocd`, `cattle-system` shipped; rest dropped.
  - **Output:** `es` → `elk-mnt.tigo.com.pa:443`, `tls On` / `tls.verify Off`, creds via env (`ES_HTTP_USER`/`ES_HTTP_PASSWD`), `Logstash_Format On` with per-namespace prefix (`_logstash_prefix` key, DateFormat `%Y.%m.%d`), `Generate_ID On`, `Replace_Dots On`, `Retry_Limit False`. **One index per namespace** `fluent-bit-glx-uat-<ns>-YYYY.MM.DD`.
  - **Parsers defined:** only `cri`, `json`, `docker`.
- 🔑 **GLX does NOT normalize application logs.** There is **no per-application parser and no multiline rule** — the CRI parser only splits `time/stream/message`, so in Kibana the `message` is the **raw plain-text line**: no `level`/`logger`/`corr_id` fields, and Java stack traces are split across many documents. GLX gives us a **proven skeleton, not a normalization solution.**
- `monitoring` namespace = kube-prometheus-stack (metrics).
- **Takeaway:** reuse the fluent-bit **skeleton** (CRI input, ES output, k8s filter, allow-list, per-ns index, the 3.1.4 image already mirrored internally); **change the destination** (SAT → own ES) and **add the L1 parsing/multiline that GLX lacks** (§6).

---

## 5. Log-format analysis (SAT dev survey)

**Every app logs plain text to stdout — no JSON.** Five distinct formats were found, all driven by the stack / base image:

### Format A — Spring "Satélite" base (logback custom)
`2026-06-23 07:21:14.268 [http-nio-8080-exec-3] DEBUG o.s.w...DispatcherServlet - <msg>`
Optionally with a correlation field: `… [thread] [<corr_id>] LEVEL logger - <msg>` (newer base).
Apps: `cr-*`, `iuc-*`, `adminntt-*`, `billing`, `tigo-spring-base`.

### Format B — Spring Boot default console
`2026-06-15T12:16:50.883-05:00  INFO 1 --- [app-name] [nio-8080-exec-4] logger : <msg>`
Apps: `payments-*` (incl. a WebFlux variant with a `[reqId]`), `emailqueue-consumer`, `mainconsumer`, `tytan-tecrep-consumer`.

### Format C — Python / FastAPI (uvicorn)
`INFO:     10.30.13.11:38658 - "GET /health HTTP/1.1" 200 OK` + multiline startup warnings (pydantic).
Apps: `tigo-python-base`, `ivrprocessapi`.

### Format D — PHP base (custom)
`  2026-06-23 07:20:18 /health ...................................... ~ 0.13ms`
Apps: `tigo-php-base`.

### Format E — nginx access (frontends)
`10.30.13.23 - - [23/Jun/2026:07:20:24 -0500] "GET /health HTTP/1.1" 200 2 "-" "kube-probe/1.32" "-"`
Apps: `cr-app-frontend`, `adminntt-app-frontend`.

### Business-logging sub-pattern (notification consumers)
`smsqueue-consumer`, `mainconsumer` use a `LogEntry` logger:
`ApiName: <x> | UTI: <uuid> | Timestamp: <t> | Comment: <c>` — **`UTI` is effectively a transaction/correlation id** already present in the message body.

### Per-application matrix

| App | Image / base | Stack | Format | Levels seen | Corr ID | Dominant content / noise |
|---|---|---|---|---|---|---|
| cr-service-getpayments-v1 | cash-register | Spring (satélite) | A | DEBUG | no | ~100% `/health` DEBUG probe noise |
| cr-service-processpayments-v1 | cash-register | Spring | A | DEBUG | no | ~100% `/health` DEBUG noise |
| iuc-service-processsap-v1 | iuc | Spring | A | INFO | no | **good** business logs (uuid in msg), FTP/file ops |
| iuc-app-backend-v1 | iuc | Spring | A | DEBUG | no | `/health` DEBUG noise |
| adminntt-service-consumer-sms-v1 | admint-ntt | Spring | A | WARN | no | **HikariCP** "failed to validate connection" spam |
| adminntt-service-consumer-email-v1 | admint-ntt | Spring | A | WARN | no | **HikariCP** spam (scheduling-1) |
| adminntt-service-notification-consumer-v1 | admint-ntt | Spring | A | DEBUG | no | `/health` DEBUG noise |
| payments-processpaymentproducer-v1 | integraciones | Spring | B | INFO | UTI in msg | **Hibernate SQL echo ON** (verbose), RMQ publish logs |
| payments-getcustomergeneralinfo-v1 | integraciones | Spring WebFlux | B | DEBUG | reqId `[…]` | `/health` DEBUG noise |
| billing-v1 | digital | Spring | A | INFO/WARN | no | **good** business logs (emoji markers) |
| emailqueue-consumer-v1 | notificationmanager | Spring | B | INFO | no | startup/Hibernate init |
| smsqueue-consumer-v1 | notificationmanager | Spring + LogEntry | A | INFO/ERROR | **UTI** (`NO_CORR_ID` field) | SMPP, stack traces |
| mainconsumer-v1 | notificationmanager | Spring + LogEntry | B | INFO/WARN/ERROR | **UTI** | business flow, stack traces |
| tytan-tecrep-consumer-v1 | tecrep | Spring | B | INFO/ERROR | no | **stack traces** (multiline join needed) |
| tigo-spring-base-v1 | base sit-1.1.0 | Spring | A + **CorrelationIdFilter** | DEBUG | **YES (generated)** | reference base; corr_id + version=1.0.0 |
| tigo-python-base-v1 | base sit-2.0.0 | Python/uvicorn | C | INFO | no | uvicorn `/health` access |
| tigo-php-base-v1 | base | PHP | D | none | no | `/health` ping log only |
| cr-app-frontend-v1 | cash-register | nginx | E | n/a | no | `/health` kube-probe access |
| adminntt-app-frontend-v1 | admint-ntt | nginx | E | n/a | no | `/health` kube-probe access |
| ivrprocessapi-v1 | notificationmanager | Python/FastAPI | C | INFO | no | uvicorn startup + multiline pydantic warning |

### Cross-cutting observations
- **DEBUG is the effective level on several Spring apps** despite `LOG_LEVEL=INFO` — the env is not wired into logback (root logger stays at DEBUG → Spring DispatcherServlet/Mapping spam).
- **`/health` probe noise is universal** (every stack), often ~100% of volume on query services.
- **No JSON anywhere**; timestamps differ (Format A space vs Format B ISO8601+offset); levels/fields are positionally different per format.
- **Correlation already exists in two places**: the new Spring base's `CorrelationIdFilter`, and the consumers' `UTI`. It is simply **not consistently adopted** and **not extracted into a field**.

---

## 6. Normalization strategy (no application code changes)

Two complementary tracks. L1 is immediate and rebuild-free; L2 is the durable fix and still touches **no app source** (only the shared base images + a CI rebuild).

### Track L1 — Pipeline normalization in fluent-bit (zero rebuild)
Runs entirely in the collector; apps are untouched. **This is the part GLX does not have** — SAT starts from GLX's skeleton (CRI input + ES output + k8s filter + allow-list + per-ns index + the mirrored 3.1.4 image) and adds the following on top:
- **Parsers (one per format A–E)** to extract `@timestamp`, `level`, `logger`, `thread`, `corr_id`/`UTI`, `message` into real fields (regex parsers).
- **Multiline** rule to join Java stack traces (continuation lines: leading spaces, `at `, `Caused by`, `...`, `~[`) into a single event — applies to A and B.
- **Drop probe noise** (`grep`/`modify` Exclude) for `/health` lines across all formats → drastically smaller, readable indices.
- **Enrich** with k8s metadata (namespace, pod, container, app label) via the `kubernetes` filter; **route** to ES; **index per namespace** `fluent-bit-sat-dev-<ns>` (GLX pattern).
- **Decision needed** on the **HikariCP WARN spam**: it is a *real reliability signal* (DB/firewall closing idle connections faster than `maxLifetime`), so the recommendation is **keep it but fix the root cause**, not silently drop it.

**L1 limits:** it can parse and drop, but it cannot reduce what the app *emits* (DEBUG apps still flood the node) and cannot invent business fields. It makes logs searchable and clean in Kibana, but the source stays noisy.

### Track L2 — Base-image standardization (rebuild, no app-source change)
Because logging is centralized in `tigo-spring-base` / `tigo-python-base` / `tigo-php-base`, a single change per base image propagates to all derived apps on their next pipeline build:
- **Emit JSON** (e.g. logback `JsonEncoder` / structured formatter) → native structured logging end-to-end, no pipeline regex needed.
- **Default level INFO** and actually wire `LOG_LEVEL` → kills the DEBUG flood at the source.
- **Exclude `/health`** from access/dispatcher logging → removes probe noise at the source.
- **Ensure `CorrelationIdFilter` in all bases** (Spring already has it; add equivalents to Python/PHP) and **log `corr_id`/`UTI` as a field**.

**L2 limits:** requires rebuilding/redeploying images (CI), and adoption depends on apps bumping their base tag (several still run older base versions).

### Recommended sequencing
1. **L1 now** (rebuild-free) → logs land structured-enough and clean in Kibana immediately.
2. **L2 in parallel** on the base images → as apps rebuild, they graduate to native JSON and the L1 regex for that format becomes redundant (keep L1 as the fallback for not-yet-rebuilt apps).

---

## 7. Proposed target for SAT dev (no apply yet)

> **Airgapped cluster (confirmed):** SAT has **no internet egress** (download.elastic.co / docker.elastic.co / cr.fluentbit.io all unreachable). All ECK / Elasticsearch / Kibana / fluent-bit **images and install manifests must be mirrored into the internal registry** (`registry-local.tigo.com.pa` / `git.tigopa.local:5050`) and applied **offline** — no `kubectl apply -f https://…`. Deployment is GitOps via **`tigo-devops-panama`** (ArgoCD), the single repo all apps already use.

**Confirmed environment facts (SAT dev):** StorageClass `nfs-storage` (default, `nfs-provisioner`, expansion enabled) · IngressClass `nginx` (rke2-ingress-nginx) · **no Prometheus** · GitOps repo `git.tigopa.local/kubernetes-panama/tigo-devops-panama.git`.

**Phase 1 — Capture + normalization**
1. **Mirror images** (ECK operator, Elasticsearch, Kibana, fluent-bit) into the internal registry; vendor the ECK install manifest offline.
2. Deploy **own Elastic + Kibana** in-cluster via **ECK** (ns `logging`; PVC on `nfs-storage`; `node.store.allow_mmap=false`), through ArgoCD/`tigo-devops-panama`.
3. Deploy **fluent-bit** (GLX pattern) → in-cluster ES, with **L1** parsers/multiline/drop and per-namespace index `fluent-bit-sat-dev-<ns>`.
4. Expose Kibana via Ingress (class `nginx`).
5. Keep **Promtail→Loki in parallel** during transition (no regression).
6. Start **L2** base-image work in parallel (JSON, INFO, drop `/health`, correlation everywhere) — single control point: the `tigo-*-base` images + `tigo-devops-panama`.

**Phase 2 — Kibana enablement**
- Data views (`fluent-bit-sat-dev-*`), per-domain dashboards (cr-*, iuc-*, adminntt-*, payments-*), index lifecycle/retention, RBAC.

**Phase 3 — Istio + Kiali (greenfield, staged)**
- Install istiod + Kiali **without** injecting any sidecar (zero app impact).
- Needs **Prometheus on SAT** for Kiali traffic graphs (SAT has only Loki/Grafana today — to provision).
- Enable injection **gradually**, low-risk apps first; **exclude** ArgoCD/RabbitMQ; consider moving business apps to a dedicated namespace first.
- mTLS `PERMISSIVE` → `STRICT`. Bonus: the proxy can stamp request/trace IDs without app code, complementing §6.

---

## 8. Open items / pending data
1. ✅ **GLX fluent-bit config — DONE:** image `fluent-bit:3.1.4` (internal registry); CRI input; ES output to `elk-mnt.tigo.com.pa:443` (TLS, verify off, env creds, per-ns `Logstash_Prefix`, `%Y.%m.%d`); parsers `cri`/`json`/`docker` only. **No per-app parser, no multiline** → confirms SAT must add L1 on top.
2. ✅ **SAT pre-flight — DONE:** StorageClass `nfs-storage` (default) · IngressClass `nginx` (rke2-ingress-nginx) · **NO internet egress → airgapped** (images must be mirrored to internal registry; offline install). All apps' GitOps repo = `tigo-devops-panama`.
3. ✅ **Prometheus on SAT — DONE:** **none present** (only Loki/Grafana). Must be provisioned for Kiali (Phase 3).
4. ⏳ **Confirm** whether GLX **prod** runs Istio/Kiali. *Pending — requires GLX prod access (not available from GLX UAT); ask platform team.*
5. ◑ **Base-image / CI ownership (Track L2):** all workloads — including `tigo-spring-base-v1`, `tigo-python-base-v1`, `tigo-php-base-v1` — are deployed from the single GitOps repo `git.tigopa.local/kubernetes-panama/tigo-devops-panama.git`. The **base-image build pipeline owner / release cadence** is still a human confirmation with the platform/CI team.

---

## Appendix A — L1 fluent-bit parser set (DRAFT, not applied)

This is the concrete normalization layer SAT adds on top of the GLX skeleton. It is **collector-only** (no app change). The `@timestamp` keeps coming from the CRI input parser; the filters below **enrich** each record with `level`, `logger`, `thread`, `corr_id`/`req_id`, and (for nginx) `method`/`path`/`status`, **while preserving the original `message`** (so joined Java stack traces stay intact). Validate with `fluent-bit --dry-run` / a test pod before any deployment.

### A.1 Pipeline order (`fluent-bit.conf`)
```
@INCLUDE input.conf            # tail + Parser cri  (same as GLX)
[FILTER] kubernetes            # k8s metadata       (same as GLX)
[FILTER] multiline  -> java_multiline    # NEW: join Java stack traces
[FILTER] parser     -> A..E (try in order)   # NEW: extract fields, preserve message
[FILTER] lua        -> set_index_prefix  # allow-list + per-ns index (GLX pattern, ns=argocd)
[FILTER] grep (Exclude /health) x2       # NEW: drop probe noise
@INCLUDE output.conf           # es -> SAT in-cluster ES (TLS, env creds)
```

### A.2 Multiline parser (`custom_parsers.conf`, referenced by `[SERVICE] Parsers_File`)
```ini
[MULTILINE_PARSER]
    name          java_multiline
    type          regex
    flush_timeout 1000
    # a line that starts with a timestamp begins a new event...
    rule          "start_state"  "/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}[.,]\d{3}.*/"  "cont"
    # ...continuation = indented lines, "at ...", "Caused by:", "... N frames omitted"
    rule          "cont"         "/^(?:[\t ]+|Caused by:|\.\.\.|\s*at\s).*/"              "cont"
```
```ini
[FILTER]
    Name                  multiline
    Match                 kube.*
    multiline.key_content message
    multiline.parser      java_multiline
```

### A.3 Format parsers (`parsers.conf`) — extraction only, message preserved
```ini
# Format A — Spring "satélite" logback (optional [corr_id])
[PARSER]
    Name   spring_a
    Format regex
    Regex  ^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \[(?<thread>[^\]]*)\](?: \[(?<corr_id>[^\]]*)\])? +(?<level>TRACE|DEBUG|INFO|WARN|ERROR) +(?<logger>[^ ]+) -

# Format B — Spring Boot default console (optional [req_id] in body)
[PARSER]
    Name   spring_b
    Format regex
    Regex  ^(?<time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[-+]\d{2}:\d{2}) +(?<level>TRACE|DEBUG|INFO|WARN|ERROR) +(?<pid>\d+) --- \[(?<app>[^\]]*)\] \[(?<thread>[^\]]*)\] (?<logger>[^ ]+) +: (?:\[(?<req_id>[^\]]*)\] )?

# Format C — Python / uvicorn
[PARSER]
    Name   uvicorn
    Format regex
    Regex  ^(?<level>DEBUG|INFO|WARNING|ERROR|CRITICAL):\s+

# Format D — PHP base (mostly /health pings, dropped downstream)
[PARSER]
    Name   php_health
    Format regex
    Regex  ^\s*(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(?<path>\S+)\s+\.+\s+~\s+(?<duration>[0-9.]+)ms

# Format E — nginx access (combined + forwarded)
[PARSER]
    Name   nginx_access
    Format regex
    Regex  ^(?<remote>[^ ]+) - (?<user>[^ ]+) \[(?<ngtime>[^\]]+)\] "(?<method>[A-Z]+) (?<path>[^ ]+) (?<protocol>[^"]+)" (?<status>\d+) (?<bytes>\d+) "(?<referer>[^"]*)" "(?<agent>[^"]*)"
```
```ini
[FILTER]
    Name         parser
    Match        kube.*
    Key_Name     message
    Parser       spring_a
    Parser       spring_b
    Parser       uvicorn
    Parser       nginx_access
    Parser       php_health
    Reserve_Data On
    Preserve_Key On
```
> `Reserve_Data On` keeps k8s metadata; `Preserve_Key On` keeps the original `message` (full multiline) — the parsers only **add** fields. Parsers are tried in order; the first to match wins; non-matching lines pass through unchanged.

### A.4 Drop probe noise (keep HikariCP — it is a real signal)
```ini
[FILTER]
    Name    grep
    Match   kube.*
    Exclude path ^/health$
[FILTER]
    Name    grep
    Match   kube.*
    Exclude message (/health|HealthController|Status: UP \| Version)
```
> Drops nginx (`path=/health`), uvicorn/Spring access (`/health` in message), and the Spring DEBUG health burst (`HealthController`, `Status: UP | Version…`). **HikariCP "failed to validate connection" is intentionally NOT dropped** — it is a genuine log signal worth keeping rather than silently discarding.

### A.5 Caveats / what L1 cannot do
- **DEBUG flood at source persists.** L1 drops health DEBUG, but DEBUG apps still emit/forward other framework noise. To cut it at the source, add an **optional** `Exclude level ^DEBUG$` (aggressive — also removes genuine debug) *or* fix the level in the base image (**Track L2**, preferred).
- **No real business fields** (txn/account/amount) and **no cross-service correlation** beyond what the app already prints (`corr_id`/`UTI`) — those require L2 / the mesh.
- Regexes are drafted from the 2026-06-23 samples; **validate against a wider sample** before rollout, and treat them as a fallback that becomes redundant per-format once L2 emits native JSON.
