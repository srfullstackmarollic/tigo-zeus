# Observabilidad — Istio (Ambient) + Kiali · SAT dev — **As-Built**

> Informe técnico · Confidencial · creado 2026-06-25 · actualizado 2026-06-26
> Cluster: `tocpait-sat-dev` (RKE2 v1.32.8, K8s 1.32) · acceso SSH al master `tocpait-sat-dev-mstrs-k8s-01`
> Repo GitOps: `tigo-devops-panama`, **branch `dev`**, dir `cluster-resources/istio/`
> Relacionado: [[sat-dev-analysis]] · [[tigo-cluster-observability-topology]]

## 0. Estado (resumen ejecutivo)

| Fase | Estado |
|---|---|
| 0 · Pre-flight | ✅ completo |
| 1 · Estructura GitOps | ✅ completo |
| 2 · Bootstrap del mesh (control + data plane) | ✅ completo y verde en ArgoCD |
| 3 · Telemetría ambient | ✅ ns `argocd` etiquetado `ambient` (130 pods), Rabbit/ArgoCD excluidos (`none` en vivo). **Pendiente: firmeza del `none` de Rabbit vía GitOps** |
| 4 · Exponer Kiali | ✅ completo — `https://k8s-dev-sat.tigo.com.pa/kiali` |

**Versiones desplegadas:** Istio **1.26.8** (ambient), kiali-server **2.11.0**, prometheus (chart) **29.13.0**.
**Sin tocar ninguna app:** ningún namespace de negocio fue etiquetado todavía; data-plane ocioso.

## 1. Contexto y problema

El cluster **SAT dev** no tenía service mesh ni observabilidad de tráfico. Conviven ~**199 workloads**
(56+ deployments de negocio + ArgoCD + RabbitMQ) en el namespace `argocd`, expuestos por un único
ingress nginx. No se sabía quién llama a quién, ni latencia, ni error rate, ni mTLS. Los diagramas
previos eran **inferidos, no evidenciados** — Istio+Kiali los vuelve evidenciados.

## 2. Objetivo

Subir Istio + Kiali siguiendo el patrón GitOps de `tigo-devops-panama`, con **máxima telemetría sin
modificar ninguna aplicación**, y dashboard de Kiali funcionando. ✅ Logrado.

## 3. Decisiones confirmadas con el cliente

- **Data-plane Ambient** (ztunnel + istio-cni): no inyecta sidecar, no reinicia pods. Grafo L4 + mTLS +
  identidad. L7 (HTTP/RPS/latencia) queda para fase opcional vía *waypoint*.
- **Entrega GitOps vía ArgoCD**, todo versionado en `cluster-resources/istio/`.
- **Prometheus:** verificar en pre-flight; si no hay, provisionar uno dedicado. → **No había** (solo
  Loki/Grafana); se provisionó uno dedicado.
- **Kiali fijado en el nodo del ArgoCD** (affinity). → Logrado con *podAffinity preferred* + toleration
  (ver §6 Fase 2).

## 4. Por qué Ambient y no Sidecar

Sidecar exige recrear/reiniciar el pod (viola "no alterar apps") y es riesgoso en `argocd`. Ambient
(istio-cni + ztunnel) intercepta el tráfico al solo etiquetar namespace/pod, sin tocar los pods.

## 5. Hallazgos del pre-flight (Fase 0) que condicionaron el diseño

| Hallazgo | Decisión derivada |
|---|---|
| **K8s 1.32.8** (RKE2) | Istio **1.26.8** (1.24 no soporta 1.32) |
| **CNI = Canal** (Flannel + Calico policy, iptables) | `cniConfDir=/etc/cni/net.d`, `cniBinDir=/opt/cni/bin`; istio-cni encadenado (`chained:true`). Compatible con ambient |
| **No hay Prometheus** (solo Loki/Grafana en ns `observability`) | Provisionar Prometheus dedicado (`prometheus.istio-system:9090`) |
| **Egress vía proxy TLS-intercept** (CA no confiada por el repo-server: `x509: unknown authority`) | **Charts Helm vendorizados en git** (`charts/`); el repo-server lee de `git.tigopa.local`. Imágenes sí bajan (los nodos confían en la CA) |
| **Nodo `nfs-01`** (K8s 1.28, cordonado, SELinux bloquea el UDS del istio-cni) | DaemonSets istio-cni/ztunnel **excluyen `nfs-01`** vía nodeAffinity (quedan 13/13) |
| **Nodo del argocd-server tiene taint `gitlab-ci=k8s-sat-dev`** | Kiali: podAffinity *preferred* + **toleration** de ese taint |
| **`tigo-tls-secret` NO existe** en el cluster (TLS termina en HAProxy externo) | Ingress de Kiali **sin** bloque tls |
| **Cluster expone por host único `k8s-dev-sat.tigo.com.pa` + routing por PATH** (no subdominio) | Kiali expuesto en **path `/kiali`** vía Ingress nginx (ver §6 Fase 4) |

## 6. Ejecución (as-built)

**Patrón del repo:** Kustomize + ArgoCD App-of-Apps. `cluster-resources/istio/` se incluye en
`cluster-resources/kustomization.yaml`; AppProject `istio` en `argocd-projects.yaml`.

### Fase 1 — Estructura GitOps (`cluster-resources/istio/`)
- `namespaces.yaml` — `istio-system` + `kiali`.
- `charts/` — charts Helm **vendorizados** (base, istiod, cni, ztunnel, kiali-server, prometheus).
- `app-istio-base / app-istiod / app-istio-cni / app-ztunnel / app-kiali / prometheus/app-prometheus` —
  ArgoCD Applications (source = git path al chart vendorizado, `targetRevision: dev`), ordenadas por
  sync-wave: base(1) → istiod(2) → cni(3) → ztunnel(4) → kiali(6); prometheus(2).
- `kiali-ingress.yaml` — Ingress nginx (ver Fase 4).
- **Sin NetworkPolicy** en `kiali` (el cluster dev no tiene hardening de namespace; ningún default-deny).

### Fase 2 — Bootstrap (control-plane + data-plane), sin tocar apps
- istiod `profile: ambient`; istio-cni + ztunnel DaemonSets (13/13, excluyendo `nfs-01`).
- Prometheus dedicado en `istio-system`.
- Kiali en ns `kiali`, fijado al nodo del argocd-server (podAffinity preferred + toleration `gitlab-ci`),
  `auth: anonymous`, Prometheus en `http://prometheus.istio-system:9090`.
- `ignoreDifferences` en base/istiod para el `caBundle`/`failurePolicy` de los ValidatingWebhooks
  (istiod los inyecta en runtime → si no, quedan OutOfSync).
- **Resultado:** 6 Applications `Synced/Healthy`; ningún pod de app reiniciado.

### Fase 3 — Telemetría ambient (enrolamento sin restart)
- **Validado** en ns canario `mesh-canary` (client→server, busybox): grafo L4 + candado mTLS en Kiali,
  pods `READY 1/1` (sin sidecar). Manifiesto descartable en `zeus/sat/mesh-canary.yaml`.
- **No existe label `project`** en pods ni deployments (solo `app`, `app.kubernetes.io/*`, `environment`).
  Por eso NO se enrola por project. Modelo elegido (**opción A**):
  - **Label de namespace** `kubectl label ns argocd istio.io/dataplane-mode=ambient` → captura TODOS los
    pods (existentes + futuros), **sin rollout**, permanente (el ns no se recrea).
  - **Exclusiones** `istio.io/dataplane-mode=none` en RabbitMQ (server-first + clustering Erlang) y en el
    control-plane de ArgoCD (`argocd-*`). **Aplicadas EN VIVO** (no por GitOps todavía).
  - **130 pods** de negocio en el mesh; los 9 (rabbit×3 + argocd×6) excluidos.
- ⚠️ **PENDIENTE — firmeza del `none` de RabbitMQ:** la label `none` en el pod **se pierde si el pod se
  recrea** → si un pod de Rabbit se recrea, **entraría al mesh** (no deseado). Para dejarlo firme hay que
  bajar `istio.io/dataplane-mode: none` al **template del StatefulSet de Rabbit** en
  `cluster-resources/rabbitmq/` (vía GitOps) — eso implica **un rollout controlado de Rabbit (3 pods)**.
  Decisión actual: seguir con `none` en vivo; tratar la firmeza después. (ArgoCD raramente reinicia, su
  `none` en vivo aguanta en la práctica.)
- Rollback inmediato: `kubectl label ns argocd istio.io/dataplane-mode-` (o por pod).
- **Verificado (2026-06-26):** ningún app sano se rompió al entrar al mesh. Los pods en CrashLoop
  (`address-repository`, `equipments-management-ar2` con ~14k restarts/50d, `services-management`,
  `mobile-packet-recharge` → `Connection to localhost:5432 refused`) son **bugs pre-existentes de
  app/DB**, NO del mesh — ambient no intercepta loopback (`localhost`). Son hallazgos que el mapeo
  justamente evidencia.

### Fase 4 — Exponer Kiali ✅
- **Desvío vs plan original** ("listener del propio mesh"): el cluster entra por **host único
  `k8s-dev-sat.tigo.com.pa` + routing por PATH**, con TLS en HAProxy externo. Por eso se expone con un
  **Ingress nginx** (`kiali-ingress.yaml`, ns kiali, path `/kiali` → `kiali:20001`), consistente con el
  resto del cluster y sin DNS/cert nuevos. El `istio-ingressgateway` + Gateway/VirtualService del mesh
  (host `kiali-dev-sat`) quedaron ociosos y **fueron removidos** en la limpieza.
- **Acceso:** `https://k8s-dev-sat.tigo.com.pa/kiali` (validado desde la VPN; sin port-forward).

## 7. Verificación end-to-end (lograda)

- `istiod`, `istio-cni`, `ztunnel`, `prometheus`, `kiali` `Running`; DaemonSets 13/13.
- Apps ArgoCD istio* `Synced/Healthy`.
- Canario `mesh-canary`: aristas L4 + candado mTLS en Kiali; pods `1/1` (prueba de "sin sidecar").
- Kiali accesible en `https://k8s-dev-sat.tigo.com.pa/kiali`.

## 8. Riesgos y notas

- **⚠️ Firmeza del `none` de RabbitMQ (PENDIENTE):** el enrolamiento es por **label de namespace**, así que
  todo pod nuevo en `argocd` entra al mesh automáticamente — incluido un pod de **Rabbit recreado**, porque
  su `none` está solo en vivo (no en el template). Meshar Rabbit puede romper AMQP/clustering Erlang. **Acción
  pendiente:** bajar `istio.io/dataplane-mode: none` al StatefulSet de Rabbit en `cluster-resources/rabbitmq/`
  (GitOps) → 1 rollout controlado de Rabbit. Mientras tanto, vigilar que Rabbit no se recree.
- **Charts vendorizados:** para subir versión de Istio/Kiali/Prometheus hay que re-vendorizar los `.tgz`
  en `charts/` (el repo-server no puede traerlos por HTTPS por el proxy TLS).
- **Label de ns aplicada en vivo:** `istio.io/dataplane-mode=ambient` en el ns `argocd` no está en GitOps
  (el ns es del bootstrap). Es permanente en la práctica (el ns no se recrea), pero documentarlo.
- **Pods server-first dentro de `argocd`:** si aparece algún workload server-first (DB embebida, etc.),
  vigilar su readiness al entrar al mesh; excluir con `=none` si hace falta.
- **L7 opcional:** para HTTP/RPS/latencia (no solo L4), desplegar *waypoint* por namespace (sin tocar
  pods) en una fase posterior.

## 9. Referencias

- Runbook operacional: `zeus/sat/sat-dev-istio-kiali-runbook.md`
- Pre-flight: `zeus/scripts/zeus-sat-istio-preflight.sh`
- Canario de prueba: `zeus/sat/mesh-canary.yaml`
- Detalle técnico original: `zeus/sat/sat-dev-istio-kiali-plan.md`
