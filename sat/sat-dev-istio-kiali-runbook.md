# Runbook operacional — Istio (ambient) + Kiali · SAT dev — **As-Built**

> Operador roda no **bastion Wallix** (kubectl apontando para `tocpait-sat-dev`). Da workstation
> NÃO há acesso direto ao cluster.
> Repo GitOps: `tigo-devops-panama`, **branch `dev`** (o ArgoCD do dev rastreia `dev`).
> Plano as-built: `plan-observabilidad-istio-kiali-sat-dev.md`.
> **Status:** Fases 0–4 concluídas; mesh no ar. Fase 3 via **label de namespace** (opção A): ns `argocd`
> `ambient` (~130 pods), Rabbit/ArgoCD excluídos com `none` **ao vivo**. **Pendente:** firmar o `none` do
> Rabbit via GitOps (template do StatefulSet) — ver Fase 3.

## Estado atual no repo (`cluster-resources/istio/`)

| Arquivo | O que é | Wave |
|---|---|---|
| `namespaces.yaml` | ns `istio-system` + `kiali` | — |
| `charts/` | charts Helm **vendorizados** (base, istiod, cni, ztunnel, kiali-server, prometheus) | — |
| `app-istio-base.yaml` | Application `base` (CRDs) | 1 |
| `app-istiod.yaml` | Application `istiod` **profile=ambient** | 2 |
| `app-istio-cni.yaml` | Application `cni` (paths Canal: `/etc/cni/net.d`, `/opt/cni/bin`) | 3 |
| `app-ztunnel.yaml` | Application `ztunnel` (DaemonSet L4; exclui `nfs-01`) | 4 |
| `app-kiali.yaml` | Application `kiali-server` (ns kiali, podAffinity preferred + toleration `gitlab-ci`) | 6 |
| `kiali-ingress.yaml` | Ingress nginx → `https://k8s-dev-sat.tigo.com.pa/kiali` | — |
| `prometheus/app-prometheus.yaml` | Prometheus dedicado (`prometheus.istio-system:9090`) | 2 |
| `gateway-api/gateway-api-crds.yaml` | CRDs Gateway API (standard v1.3.0) **vendorizadas** — pré-req do waypoint | — |
| `waypoint/waypoint.yaml` | `Gateway argocd-waypoint` (L7, escopo service) no ns `argocd` | — |

Wiring: AppProject `istio` em `argocd-projects.yaml`; `- istio` em `cluster-resources/kustomization.yaml`.
**Versões:** Istio **1.26.8**, kiali-server **2.11.0**, prometheus (chart) **29.13.0**.
**Sem NetworkPolicy** no ns kiali (cluster dev sem hardening de namespace). **Sem mesh-gateway**
(exposição é via nginx). `istioctl` **não** está no bastion → validar por `kubectl`/Kiali.

> **Particularidades do ambiente** (descobertas no pre-flight): K8s 1.32 (→ Istio 1.26); CNI **Canal**;
> **não há Prometheus** (só Loki/Grafana) → provisionado um dedicado; **proxy TLS-intercept** no egress
> → charts **vendorizados no git** (o `argocd-repo-server` não confia na CA; imagens públicas baixam
> normal); `tigo-tls-secret` **não existe** (TLS no HAProxy externo) → Ingress sem bloco `tls`.

---

## Fase 0 — pre-flight (read-only) — ✅ feito

```bash
bash zeus-sat-istio-preflight.sh      # zeus/scripts/; read-only
```
Resultado já incorporado no design (tabela §5 do plano).

## Fase 2 — bootstrap (já aplicado via push na `dev`). Validar estado:

```bash
# Applications verdes
kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  | grep -Ei 'istio|ztunnel|kiali|prometheus'
# control-plane
kubectl -n istio-system get pods
kubectl -n istio-system get ds istio-cni-node ztunnel    # 13/13 (sem o nfs-01)
kubectl -n kiali get pods -o wide                        # 1/1 no nó do argocd-server
```
Esperado: `istio-base, istiod, istio-cni, ztunnel, kiali, istio-prometheus` `Synced/Healthy`.

> Se algo voltar a `OutOfSync` no `caBundle` dos ValidatingWebhooks, já há `ignoreDifferences` em
> base/istiod. Para forçar releitura: `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.

## Fase 3 — telemetria ambient — **opção A: label de namespace** (feito)

**Canário (validado):** `kubectl apply -f mesh-canary.yaml` → grafo L4 + mTLS; pods `1/1`. Remover:
`kubectl delete ns mesh-canary`.

**NÃO existe label `project`** em pods/deployments → enrolagem por **namespace**. Ordem importa:
exclui Rabbit/ArgoCD **antes** de rotular o ns.

```bash
# 1) excluir RabbitMQ + control-plane do ArgoCD (sem restart) — ANTES do label do ns
for p in $(kubectl -n argocd get pods -o name | grep -E '/(rabbitmq|argocd-)'); do
  kubectl -n argocd label "$p" istio.io/dataplane-mode=none --overwrite ; done
kubectl -n argocd get pods -L istio.io/dataplane-mode | grep -E 'rabbitmq|argocd-'   # tem que mostrar 'none'

# 2) rotular o ns argocd (captura todos os pods, existentes + futuros, sem restart)
kubectl label ns argocd istio.io/dataplane-mode=ambient --overwrite
kubectl get ns argocd --show-labels | tr ',' '\n' | grep dataplane

# 3) validar (READY 1/1, RESTARTS inalterado; total ~ todos menos os 9 excluídos)
kubectl -n argocd get pods -l istio.io/dataplane-mode=ambient -o name | wc -l
```

No Kiali (Traffic Graph, ns `argocd`, Last 30m, **Idle Nodes ON**): aparece o conjunto; arestas surgem com o tráfego real.

> **⚠️ Firmeza do `none` do Rabbit (PENDENTE):** a label `none` no pod **some se o pod recriar**; como o
> ns está `ambient`, um pod de Rabbit recriado **entra no mesh** (risco AMQP/clustering). Firmar baixando
> `istio.io/dataplane-mode: none` no **template do StatefulSet** em `cluster-resources/rabbitmq/` (GitOps)
> → 1 rollout controlado do Rabbit. Até lá, **não recriar o Rabbit** sem reaplicar o `none`.
>
> **Permanência total via GitOps (opcional):** a label de ns já cobre tudo sem mexer em templates. Se um
> dia quiserem 100% versionado por workload, usar um patch em massa estilo `ci/patch_tz.py` nos overlays.

**Rollback imediato:**
```bash
kubectl label ns argocd istio.io/dataplane-mode-          # tira a captura do ns inteiro, na hora
# (por pod:  kubectl -n argocd label pod <nome> istio.io/dataplane-mode-)
```

## Fase 4 — exposição do Kiali — ✅ feito

Exposto pelo padrão do cluster (host único + path), **não** pelo mesh-gateway:

```bash
kubectl -n kiali get ingress         # host k8s-dev-sat.tigo.com.pa, path /kiali -> kiali:20001
```
Acesso: **`https://k8s-dev-sat.tigo.com.pa/kiali`** (TLS no HAProxy externo; auth `anonymous`).

**Acesso alternativo via port-forward** (se precisar sem passar pelo HAProxy):
```bash
kubectl -n kiali port-forward svc/kiali 20001:20001
# da VM Windows, túnel: ssh -L 20001:localhost:20001 <user>@10.30.13.6  -> http://localhost:20001/kiali
```

---

## Fase 5 — L7 via waypoint (PILOTO, opcional) — feito

Ambient (ztunnel) só dá **L4**. Para **RPS/latência/% erro/códigos HTTP** sobe-se um **waypoint** (Envoy
gerenciado pelo istiod), sem tocar nos pods. Pré-req: **CRDs da Gateway API** (vendorizadas no git;
o istiod 1.26 não as instala e o repo-server não as baixa pelo proxy TLS).

```bash
# validar pré-req + waypoint no ar
kubectl get crd | grep gateway.networking.k8s.io            # 5 CRDs (standard v1.3.0)
kubectl get gatewayclass istio-waypoint                     # criada pelo istiod
kubectl -n argocd get gateway.gateway.networking.k8s.io argocd-waypoint   # PROGRAMMED=True
kubectl -n argocd get pods -l gateway.networking.k8s.io/gateway-name=argocd-waypoint   # 1/1 Running
```

**Vincular um serviço (ao vivo, reversível).** ⚠️ Confirmar que a porta é HTTP antes (o waypoint parseia
como HTTP; serviço não-HTTP pode quebrar). O label **persiste** (selfHeal não reverte).

```bash
# 1) checar protocolo da porta (name http* ou appProtocol http -> ok; sniffing cobre porta 80 sem nome)
kubectl -n argocd get svc <svc> -o jsonpath='{range .spec.ports[*]}{.name}{" appProto="}{.appProtocol}{"\n"}{end}'
# 2) vincular (não recria pod)
kubectl -n argocd label svc <svc> istio.io/use-waypoint=argocd-waypoint --overwrite
# 3) gerar tráfego de teste de DENTRO do mesh (ns argocd já é ambient)
kubectl -n argocd run wptest --rm -it --restart=Never --image=curlimages/curl -- \
  sh -c 'for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://<svc>/; sleep 1; done'
# 4) confirmar L7 direto no waypoint (e depois no Kiali: nó de serviço + HTTP RPS/% error/códigos)
kubectl -n argocd exec deploy/argocd-waypoint -c istio-proxy -- \
  curl -s localhost:15020/stats/prometheus | grep istio_requests_total | head
```

> Piloto feito com `cr-service-processpayments-v1-services` (porta 80, sem nome → sniffing pegou como HTTP).
> O Prometheus **já raspa** o waypoint (métricas chegam ao Kiali sem ajuste de scrape).
>
> **Reversão:** `kubectl -n argocd label svc <svc> istio.io/use-waypoint-` (imediato, sem restart).
> **Ampliar** (ex.: todos `payments-*`): mesmo label por Service; todos compartilham o mesmo pod waypoint.
> **Firmeza GitOps:** o label de vinculação está **ao vivo** (mesma dívida do ns/Rabbit); para versionar,
> baixar `istio.io/use-waypoint` no Service do overlay do app.

## Verificação end-to-end (checklist)

- [ ] Applications istio*/kiali*/prometheus `Synced/Healthy`.
- [ ] istiod, istio-cni, ztunnel, prometheus, kiali `Running`; DaemonSets 13/13.
- [ ] Após enrolar um `project`: grafo no Kiali com **arestas L4** + **cadeado mTLS**.
- [ ] **Apps intactas**: `RESTARTS` inalterado, `READY` = `1/1` (não `2/2`).
- [ ] Kiali acessível em `https://k8s-dev-sat.tigo.com.pa/kiali`.

## Operação / manutenção

- **Subir versão (Istio/Kiali/Prometheus):** re-vendorizar os `.tgz` em `cluster-resources/istio/charts/`
  (o repo-server não busca por HTTPS por causa do proxy TLS), commit + push na `dev`.
- **Forçar sync:** `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.
- **L7 (HTTP/RPS/latência), opcional:** deploy de *waypoint* por namespace (sem tocar pods), fase futura.

## Rollback total

```bash
# tirar captura de todos os pods/ns enrolados (imediato, sem restart):
kubectl -n argocd label pod -l istio.io/dataplane-mode=ambient istio.io/dataplane-mode-
# remover o mesh inteiro: reverter o commit na dev; ArgoCD (prune:true) remove as Applications.
#   recursos de Applications sem finalizer ficam órfãos -> limpar com kubectl se necessário.
```
