# Resumo da sessão — Istio (ambient) + Kiali no SAT dev

> Período: 2026-06-25 → 2026-06-26 · Cluster `tocpait-sat-dev` (RKE2, K8s 1.32)
> Repo GitOps: `tigo-devops-panama` @ branch **`dev`** · Docs: `plan-observabilidad-istio-kiali-sat-dev.md` (as-built) e `sat-dev-istio-kiali-runbook.md`

## Objetivo
Subir Istio (modo **ambient**) + Kiali via GitOps no SAT dev, obtendo telemetria de tráfego
(grafo L4 + mTLS) **sem alterar/reiniciar as aplicações**, e expor o dashboard do Kiali.

## Resultado
✅ **Entregue e validado de ponta a ponta.** Kiali acessível em
**`https://k8s-dev-sat.tigo.com.pa/kiali`**; ns `argocd` capturado pelo mesh (≈130 pods),
Rabbit e ArgoCD fora; nenhum app saudável reiniciou ou quebrou.

---

## O que foi feito (cronológico)

### 1. Pre-flight (Fase 0) — read-only no bastion
Descobertas que moldaram o desenho:
- **K8s 1.32.8** → escolhido **Istio 1.26.8** (1.24 não suporta 1.32).
- **CNI = Canal** (Flannel + Calico policy, iptables) → `cniConfDir=/etc/cni/net.d`, `cniBinDir=/opt/cni/bin`.
- **Não há Prometheus** (só Loki/Grafana) → provisionado um **Prometheus dedicado**.
- **Egress via proxy TLS-intercept** (o `argocd-repo-server` não confia na CA: `x509: unknown authority`).
- Nó `nfs-01` (K8s 1.28, cordonado, SELinux) incompatível; nó do argocd-server com taint `gitlab-ci`.
- `tigo-tls-secret` não existe (TLS termina no HAProxy); cluster usa host único + routing por path.

### 2. Estrutura GitOps + bootstrap (Fases 1–2)
- Criado `cluster-resources/istio/` (App-of-Apps): `base, istiod (ambient), cni, ztunnel, kiali, prometheus`.
- **Charts Helm vendorizados no git** (`charts/`) — contorna o proxy TLS; imagens seguem vindo dos
  registries públicos (os nós confiam na CA).
- AppProject `istio` + inclusão no `cluster-resources/kustomization.yaml`.
- Bootstrap aplicado via push na `dev`; control-plane no ar sem tocar nas apps.

### 3. Correções durante o rollout
- **Kiali `Pending`** (taint `gitlab-ci` no nó do argocd-server) → podAffinity *preferred* + toleration.
- **`istio-cni`/`ztunnel` em CrashLoop no `nfs-01`** (SELinux/UDS) → `nodeAffinity` excluindo o nó (13/13).
- **Kiali timeout no kube-API** → a `netpol-kiali` (CIDR errado + egress incompleto) foi **removida**
  (cluster dev não tem hardening de namespace).
- **`OutOfSync` nos ValidatingWebhooks** (caBundle injetado em runtime) → `ignoreDifferences`.

### 4. Exposição (Fase 4)
- Exposto via **Ingress nginx** em `https://k8s-dev-sat.tigo.com.pa/kiali` (padrão do cluster:
  host único + path; TLS no HAProxy). Validado da VPN.
- **Limpeza:** removidos `istio-ingressgateway` + `kiali-gateway` (mesh listener ocioso) e o bloco
  `tls` no-op do Ingress.

### 5. Rollout da telemetria (Fase 3) — **opção A: label de namespace**
- Constatado que **não existe label `project`** em pods/deployments.
- `kubectl label ns argocd istio.io/dataplane-mode=ambient` → captura todos os pods (existentes +
  futuros), **sem restart**, permanente.
- Exclusões `istio.io/dataplane-mode=none` em **RabbitMQ** e **argocd-*** (server-first / control-plane).
- Validado em ns canário `mesh-canary` (grafo L4 + mTLS) antes do rollout real.
- **Verificado:** nenhum app saudável quebrou; os CrashLoops (`address-repository`,
  `equipments-management-ar2` ~14k restarts, `services-management`, `mobile-packet-recharge` →
  `localhost:5432`) são **bugs pré-existentes de app/DB**, não do mesh (ambient não toca loopback).

## Commits na branch `dev` (`tigo-devops-panama`)
1. `feat(istio)` — mesh ambient + Kiali via GitOps
2. `fix(istio)` — vendoriza Helm charts no git (proxy TLS)
3. `fix(istio)` — Kiali Pending + cni/ztunnel no nfs-01
4. `fix(istio)` — remove netpol-kiali (egress kube-API)
5. `chore(istio)` — ignoreDifferences caBundle dos webhooks
6. `feat(istio)` — expõe Kiali via Ingress nginx
7. `chore(istio)` — remove mesh-gateway ocioso + tls no-op

Ações de runtime (kubectl, fora do GitOps): `mesh-canary`, label do ns `argocd`, `none` em Rabbit/ArgoCD,
limpeza de recursos órfãos do ingressgateway.

## Versões fixadas
Istio **1.26.8** · kiali-server **2.11.0** · prometheus (chart) **29.13.0**.

## Pendências
- **⚠️ Firmar o `none` do RabbitMQ via GitOps** (template do StatefulSet em `cluster-resources/rabbitmq/`):
  hoje o `none` é só ao vivo → um pod do Rabbit recriado **entraria no mesh**. Fazer antes de qualquer
  manutenção/rollout do Rabbit (custa 1 rollout controlado dos 3 pods).
- Label do ns `argocd` está **ao vivo** (não no GitOps; o ns é do bootstrap) — permanente na prática.
- Opcional: L7 (HTTP/RPS/latência) via **waypoint** por namespace; derrubar `mesh-canary` quando não usar.

## Artefatos (em `zeus/`)
- `sat/plan-observabilidad-istio-kiali-sat-dev.md` — plano as-built
- `sat/sat-dev-istio-kiali-runbook.md` — runbook operacional
- `sat/mesh-canary.yaml` — teste descartável
- `scripts/zeus-sat-istio-preflight.sh` — pre-flight
