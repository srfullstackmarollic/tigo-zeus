# Runbook de execução — Istio (ambient) + Kiali · SAT dev

> Operador roda no **bastion Wallix** (kubectl apontando para `tocpait-sat-dev`).
> Daqui (workstation) NÃO há acesso direto ao cluster — só os arquivos GitOps foram preparados.
> Repo: `tigo-devops-panama` (branch `main`). Plano: `plan-observabilidad-istio-kiali-sat-dev.md`.

## O que já está pronto (Fase 1, no repo, NÃO aplicado)

Em `tigo-devops-panama/cluster-resources/istio/`:

| Arquivo | O que é | Wave |
|---|---|---|
| `namespaces.yaml` | ns `istio-system` + `kiali` (rotulados) | — |
| `netpol-kiali.yaml` | NetworkPolicy do ns `kiali` | — |
| `app-istio-base.yaml` | Application Helm `base` (CRDs) | 1 |
| `app-istiod.yaml` | Application Helm `istiod` **profile=ambient** | 2 |
| `app-istio-cni.yaml` | Application Helm `cni` (ambient) | 3 |
| `app-ztunnel.yaml` | Application Helm `ztunnel` (DaemonSet L4) | 4 |
| `app-istio-ingressgateway.yaml` | Application Helm `gateway` | 5 |
| `app-kiali.yaml` | Application Helm `kiali-server` (ns kiali, podAffinity ao argocd-server) | 6 |
| `app-kiali-gateway.yaml` + `kiali-gateway/` | Gateway+VirtualService expondo Kiali | 7 |
| `prometheus/app-prometheus.yaml` | Prometheus dedicado (**comentado**; só se não houver um) | 2 |

Wiring: `istio` AppProject em `argocd-projects.yaml`; `- istio` em `cluster-resources/kustomization.yaml`.
Versões fixadas: **Istio 1.24.3**, **kiali-server 2.4.0**, **prometheus 25.27.0**.

---

## Fase 0 — pre-flight (ANTES de fazer merge)

```bash
bash zeus-sat-istio-preflight.sh      # zeus/scripts/; read-only; enviar output de volta
```

Decisões que o output fecha **antes do merge**:
1. **Prometheus existe?** Se sim → editar `app-kiali.yaml` › `external_services.prometheus.url`
   para a URL real. Se não → descomentar `- prometheus/app-prometheus.yaml` no
   `cluster-resources/istio/kustomization.yaml` (e preencher `storageClass`).
2. **Versão K8s/RKE2** compatível com Istio 1.24? Se não, alterar `targetRevision` nos 5
   Applications istio (manter todos iguais).
3. **Paths de CNI do RKE2** (passo 3). Se não forem `/etc/cni/net.d` + `/opt/cni/bin`,
   ajustar `cni.cniConfDir`/`cni.cniBinDir` em `app-istio-cni.yaml` (ver nota no arquivo).
4. **Egress/airgap**: se sem internet, espelhar imagens istio/kiali/prometheus no registry
   interno e trocar os `repoURL`/imagens.

---

## Fase 2 — bootstrap do mesh (merge → ArgoCD sincroniza). NÃO toca nas apps.

```bash
# 1. merge no tigo-devops-panama (após ajustes da Fase 0)
git -C tigo-devops-panama add cluster-resources/istio cluster-resources/kustomization.yaml \
    cluster-resources/argocd-projects/argocd-projects.yaml
git -C tigo-devops-panama commit -m "feat(istio): mesh ambient + Kiali via GitOps (SAT dev)"
git -C tigo-devops-panama push origin main

# 2. acompanhar o sync (App-of-Apps já sincroniza cluster-resources automaticamente)
argocd app list | grep -E 'istio|ztunnel|kiali'
argocd app sync istio-base istiod istio-cni ztunnel istio-ingressgateway kiali kiali-gateway   # se preciso forçar

# 3. validar control-plane
kubectl -n istio-system get pods           # istiod, istio-cni-*, ztunnel-* Running
kubectl -n istio-system get ds ztunnel istio-cni-node   # ztunnel em TODOS os nós
istioctl version
istioctl x precheck
```

> **Neste ponto NENHUM namespace de app está enrolado → zero impacto nos workloads.**

---

## Fase 3 — habilitar telemetria ambient (rótulo de ns, SEM restart)

Começar por **1 ns de baixo risco** (canary). As apps estão no ns `argocd` — **não enrolar
o `argocd` inteiro de cara**. Validar primeiro num ns de teste/dedicado.

```bash
# canary
kubectl label namespace <ns-canary> istio.io/dataplane-mode=ambient
kubectl get ns --show-labels | grep ambient

# prova de que NADA reiniciou (ambient, sem sidecar): RESTARTS inalterado, READY continua 1/1 (não 2/2)
kubectl get pods -n <ns-canary> -o wide

# expandir gradualmente após validar no Kiali. Endurecer mTLS só depois:
# kubectl apply -f -  <<'EOF'  (PeerAuthentication STRICT por ns, opcional, pós-validação)
```

---

## Fase 4 — expor Kiali + dashboard

```bash
# Gateway+VirtualService já sobem no wave 7. Garantir host no DNS/HAProxy:
#   kiali-dev-sat.tigo.com.pa  -> istio-ingressgateway (TLS termina no HAProxy externo)
kubectl -n istio-system get gateway kiali-gateway
kubectl -n istio-system get virtualservice kiali-vs
kubectl -n kiali get pod -o wide          # confirmar agendado no nó do argocd-server

# abrir: https://kiali-dev-sat.tigo.com.pa/kiali
```

Auth = `anonymous` (dev). Avaliar `openid` com o Keycloak existente em fase posterior.

---

## Verificação end-to-end (checklist)

- [ ] `istioctl x precheck` e `istioctl version` sem erros.
- [ ] istiod, istio-cni e ztunnel `Running` (ztunnel em todos os nós).
- [ ] `kubectl get ns --show-labels | grep ambient` → ns enrolado(s).
- [ ] Kiali: grafo do ns enrolado com **arestas L4** + **cadeado mTLS**, sem warning de Prometheus.
- [ ] **Apps intactas**: `kubectl get pods -n <ns>` → `RESTARTS` inalterado, `READY` = `1/1` (não `2/2`).
- [ ] ArgoCD: Applications istio*/kiali* `Synced`/`Healthy`; Kiali no nó do argocd-server.

## Rollback

```bash
# remover captura de um ns (volta ao estado anterior na hora, sem restart)
kubectl label namespace <ns> istio.io/dataplane-mode-

# remover o mesh inteiro: reverter o commit; ArgoCD (prune:true) remove os Applications e recursos.
```
