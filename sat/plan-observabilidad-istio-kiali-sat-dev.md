# Plan de Implementación de Observabilidad — Istio (Ambient) + Kiali · SAT dev

> Informe técnico · Confidencial · 2026-06-25
> Cluster: `tocpait-sat-dev` (RKE2) · Identificación pa = Panamá
> Relacionado: [[sat-dev-analysis]] · [[tigo-cluster-observability-topology]]

## 1. Contexto y problema

El cluster **SAT dev** (`tocpait-sat-dev`, RKE2, acceso por SSH al master
`tocpait-sat-dev-mstrs-k8s-01`) no tiene service mesh ni observabilidad de tráfico. Hoy conviven
**56 deployments de negocio + el propio ArgoCD + RabbitMQ** todos en el namespace `argocd`
(anti-pattern, sin aislamiento de blast-radius), expuestos por un único ingress nginx.

No se sabe quién llama a quién, ni latencia, ni tasa de error, ni mTLS entre servicios. Los diagramas
actuales son en gran parte **inferidos, no evidenciados**.

## 2. Objetivo

Subir Istio + Kiali en SAT dev siguiendo el patrón GitOps del repo `tigo-devops-panama`, obteniendo
el **máximo de telemetría sin modificar ninguna aplicación**, exponer Kiali por un listener del
propio mesh y tener el dashboard de Kiali funcionando.

## 3. Decisiones confirmadas con el cliente

- **Modo de data-plane: Ambient** (ztunnel + istio-cni), activado por label de namespace. No inyecta
  sidecar, no reinicia ni altera los pods de las apps. Entrega grafo L4 + mTLS + identidad en Kiali.
  L7 (HTTP/RPS/latencia) queda para fase opcional vía waypoint.
- **Entrega: GitOps vía ArgoCD** — versionar todo en `cluster-resources/`.
- **Prometheus:** verificar en pre-flight; si no existe, provisionar uno dedicado a Istio.
- **Kiali fijado en el nodo del ArgoCD** (nodeSelector/affinity).

## 4. Por qué Ambient y no Sidecar

El Istio sólo genera telemetría si hay data-plane. Sidecar exige recrear/reiniciar el pod (viola "no
alterar las aplicaciones") y es riesgoso en el ns `argocd`. Ambient (istio-cni + ztunnel) intercepta
el tráfico al sólo etiquetar el namespace, sin tocar los pods.

## 5. Patrón del repo tigo-devops-panama

Kustomize + ArgoCD App-of-Apps + ApplicationSet. El repo ya está "istio-ready" pero nada de Istio
instalado. Ingress nginx, TLS en HAProxy externo, secret `tigo-tls-secret`.

## 6. Fases de ejecución

Fase 0 pre-flight, Fase 1 estructura GitOps, Fase 2 bootstrap del mesh, Fase 3 telemetría ambient,
Fase 4 exponer Kiali.

## 7. Verificación end-to-end

## 8. Riesgos y notas
</content>
</invoke>
