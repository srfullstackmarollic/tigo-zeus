# Observabilidade SAT dev — Istio (ambient) + Kiali via GitOps

## Contexto

O cluster **SAT dev** (`tocpait-sat-dev`, RKE2, acesso por SSH ao master `tocpait-sat-dev-mstrs-k8s-01`)
não tem service mesh nem observabilidade de tráfego. Hoje há 56 deployments de negócio + o próprio ArgoCD +
RabbitMQ todos no ns `argocd` (anti-pattern já documentado em `sat-dev-analysis.md`), expostos por um único
ingress nginx. Não há visibilidade de quem chama quem, latência, taxa de erro nem mTLS entre serviços.

**Objetivo:** subir Istio + Kiali em SAT dev seguindo o padrão GitOps do repo `tigo-devops-panama`, obtendo o
**máximo de telemetria sem alterar nenhuma aplicação**, expor o Kiali por um listener do próprio mesh e ter o
dashboard do Kiali funcionando.

**Decisões (confirmadas com o cliente):**
- **Modo de data-plane: Ambient** (ztunnel + istio-cni). Ativado por *label de namespace* — **não injeta sidecar,
  não reinicia nem altera os pods das apps**. Entrega grafo L4 + mTLS + identidade no Kiali. L7 (HTTP/RPS/latência)
  fica para uma fase 2 opcional via *waypoint* (também sem tocar nos pods).
- **Entrega: GitOps via ArgoCD** — versionar tudo em `tigo-devops-panama/cluster-resources/` e deixar o ArgoCD
  sincronizar (App-of-Apps existente).
- **Prometheus: verificar no pre-flight**; se não existir, provisionar um Prometheus dedicado ao Istio.
- **Kiali fixado no nó do ArgoCD** (nodeSelector/affinity), localização determinística em dev.

## Padrão do repo (descoberto)

- Kustomize + ArgoCD **App-of-Apps + ApplicationSet** (`applicationsets/roots.yaml`, generator
  `apps/overlays/*/*/api/*`). Add-ons de plataforma ficam em `cluster-resources/` (ex.: `keycloak/`, `redis/`,
  `rabbitmq/`, `nfs/`, `namespace-hardening/`), incluídos por `cluster-resources/kustomization.yaml`.
- O repo **já está "istio-ready"**: `cluster-resources/namespace-hardening/argocd/networkpolicy-allow-istio.yaml`
  referencia `istio-system`, mas **nada de Istio está instalado**.
- Ingress: `ingressClassName: nginx`, TLS termina em **HAProxy externo** (`ssl-redirect: "false"`), secret
  `tigo-tls-secret`, host `k8s-<env>-sat.tigo.com.pa`.
- repoURL: `https://git.tigopa.local/kubernetes-panama/tigo-devops-panama.git`, `targetRevision: main`,
  syncPolicy `automated {prune, selfHeal}`.

---

## Fase 0 — Pre-flight (read-only, no bastion)

Rodar no master via SSH (kubeconfig do rke2). Coletar e anexar a `outs-cmd.txt`:

1. **Prometheus/Grafana existentes?** `kubectl get ns`; `kubectl get pods -A | grep -iE 'promet|grafana|monitor|observab'`.
   Define se reaproveitamos um Prometheus ou provisionamos um novo.
2. **Nó do ArgoCD:** `kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-server -o wide` → anotar o nó
   (para o nodeSelector do Kiali).
3. **CNI do RKE2:** `kubectl get pods -n kube-system | grep -iE 'canal|calico|cilium|flannel'` e
   `kubectl get installation -A 2>/dev/null` → validar compatibilidade do `istio-cni`/ztunnel (ambient).
4. **StorageClass / IngressClass:** `kubectl get sc`; `kubectl get ingressclass` (confirmar `nginx`).
5. **Egress de imagens:** confirmar acesso a `docker.io/istio/*` e `quay.io/kiali/*` (ou mirror interno se airgapped).
6. **Versão do K8s/RKE2** (compatibilidade da versão do Istio a fixar).

> Se o cluster for airgapped, espelhar imagens `istio/{pilot,install-cni,ztunnel,proxyv2}`, `quay.io/kiali/kiali`
> e Prometheus no registry interno antes da Fase 2.

---

## Fase 1 — Estrutura GitOps (sem aplicar nada ainda)

No repo `/Users/rmd/projects/marollic/tigo/tigo-devops-panama`, criar o diretório de plataforma do mesh seguindo
o estilo de `cluster-resources/keycloak/`:

```
cluster-resources/istio/
├── kustomization.yaml
├── namespaces.yaml            # istio-system, istio-cni (labels: environment, component: service-mesh)
├── istio-base/                # CRDs + base (Helm chart istio/base, versão fixa)
├── istiod/                    # control-plane, profile=ambient
├── istio-cni/                 # istio-cni (necessário p/ ambient)
├── ztunnel/                   # DaemonSet ztunnel (data-plane ambient)
├── istio-ingressgateway/      # gateway p/ expor Kiali pelo mesh ("listener service-mesh")
├── prometheus/                # SÓ se Fase 0 indicar que não há Prometheus
└── kiali/                     # Deployment Kiali + CR + nodeSelector no nó do ArgoCD
```

- **Charts Helm do Istio via Kustomize:** usar os charts oficiais (`istio/base`, `istiod`, `cni`, `ztunnel`,
  `gateway`) com **versão fixada** (`profile: ambient` no istiod). Empacotar como ArgoCD Applications
  (multi-source / Helm) seguindo o padrão de `applicationsets/roots.yaml`.
- **AppProject:** adicionar projeto `istio` em `cluster-resources/argocd-projects/argocd-projects.yaml`
  (ou reusar `default`) com permissão para `istio-system`, `istio-cni`, `kiali`.
- **Incluir** o novo dir em `cluster-resources/kustomization.yaml`.
- **NetworkPolicies:** estender `namespace-hardening/` para liberar tráfego do/para `istio-system` e o ns do Kiali
  (a base `networkpolicy-allow-istio.yaml` já existe — só ampliar para Kiali↔Prometheus↔istiod).

### Componentes-chave a versionar

- **istiod** `profile: ambient`, `istio-system`.
- **istio-cni** + **ztunnel** (DaemonSets) — o data-plane ambient. Nenhuma alteração nos pods das apps.
- **Kiali** (`quay.io/kiali/kiali`): CR apontando `external_services.prometheus.url` para o Prometheus
  (existente ou o provisionado), `auth.strategy` (ver Fase 4), e
  `nodeSelector`/`affinity` para o nó do ArgoCD (resultado do pre-flight passo 2).
- **istio-ingressgateway** + **Gateway/VirtualService** roteando para o Service do Kiali — o "listener
  service-mesh apontando para o Kiali". Coexiste com o nginx atual (sem substituí-lo nesta fase).

---

## Fase 2 — Bootstrap do mesh (control-plane + data-plane), sem tocar nas apps

1. Merge no `tigo-devops-panama` → ArgoCD sincroniza `istio-base` → `istiod (ambient)` → `istio-cni` → `ztunnel`.
   Nesta etapa **nenhum namespace de app está enrolado** ainda → zero impacto nos workloads.
2. Validar control-plane: `istioctl version`, `kubectl -n istio-system get pods`, `istioctl x precheck`,
   ztunnel `Running` em todos os nós.
3. (Se necessário) subir o **Prometheus** dedicado ao Istio e confirmar scrape dos componentes do mesh.

## Fase 3 — Habilitar telemetria ambient (rótulo de namespace, sem restart)

Captura de tráfego sem alterar pods:

1. Começar por **1 namespace de baixo risco** (canary). Se as apps de negócio estão hoje no ns `argocd`, a
   recomendação é **enrolar primeiro um ns dedicado** (`sat-apps`) ou validar em um ns de teste antes de tocar no
   `argocd`. Decisão de qual ns enrolar primeiro fica para a execução, com base no pre-flight.
2. `kubectl label namespace <ns> istio.io/dataplane-mode=ambient` → o ztunnel passa a capturar o tráfego L4
   daquele ns. Pods **não reiniciam**.
3. Verificar no Kiali que aparecem nós/arestas L4 e mTLS para os serviços daquele namespace.
4. Expandir gradualmente para os demais namespaces conforme validação. **Não** enrolar o ns `argocd` inteiro de
   uma vez sem validar o impacto no próprio ArgoCD/RabbitMQ.

> mTLS em ambient é automático em modo permissivo; endurecer (`PeerAuthentication STRICT`) por namespace só depois
> da validação.

## Fase 4 — Expor Kiali + dashboard

1. **Listener service-mesh:** aplicar o `Gateway` + `VirtualService` (istio-ingressgateway) com host
   `kiali-dev-sat.tigo.com.pa` apontando para o Service do Kiali. Reutilizar `tigo-tls-secret` e o padrão de host
   `*-<env>-sat.tigo.com.pa`; SSL termina no HAProxy externo (`ssl-redirect: false`).
2. **Auth do Kiali:** dev → `anonymous` (ou `token`) para acesso rápido; recomendado avaliar `openid` com o
   Keycloak (`keycloak-*`) já existente no repo numa fase posterior.
3. **Dashboard Kiali:** validar a UI do Kiali (grafo, health, mTLS badges) no host acima. Opcional: importar os
   dashboards Grafana oficiais do Istio se houver Grafana, apontando para o mesmo Prometheus.

---

## Verificação (end-to-end)

- `istioctl x precheck` e `istioctl version` sem erros; istiod, istio-cni e ztunnel `Running`.
- `kubectl get ns --show-labels | grep ambient` → namespace(s) enrolado(s).
- No Kiali (`https://kiali-dev-sat.tigo.com.pa`): grafo mostra os serviços do ns enrolado com **arestas de tráfego
  L4** e **cadeado mTLS**; sem warnings de "missing Prometheus".
- **Prova de que apps não mudaram:** `kubectl get pods -n <ns>` → `RESTARTS` inalterado e **sem** container extra
  (`READY` continua `1/1`, não `2/2`) — confirma ambient (sem sidecar).
- ArgoCD: todas as Applications de Istio/Kiali `Synced`/`Healthy`; Kiali agendado no nó do ArgoCD
  (`kubectl get pod -n kiali -o wide`).

## Riscos / notas

- **Ambient sobre RKE2/Canal:** istio-cni/ztunnel precisam ser validados no pre-flight (passo 3). Se incompatível,
  fallback = sidecar só em ns canary (cobertura parcial) — confirmar com o cliente antes.
- **ns `argocd` compartilhado:** não enrolar de uma vez; preferir ns dedicado/canary primeiro para não arriscar o
  ArgoCD/RabbitMQ.
- **Egress/airgap:** garantir imagens do Istio/Kiali/Prometheus (mirror interno se necessário).
- **Versão do Istio:** fixar versão compatível com o K8s do RKE2 (pre-flight passo 6).

## Arquivos de referência (repo tigo-devops-panama)

- `applicationsets/roots.yaml` — modelo de Application/App-of-Apps.
- `cluster-resources/kustomization.yaml` — onde incluir `istio/`.
- `cluster-resources/keycloak/stable/` — exemplo de add-on bem estruturado (namespace + kustomization + ingress).
- `cluster-resources/namespace-hardening/argocd/networkpolicy-allow-istio.yaml` — NetPol istio já existente, a ampliar.
- `cluster-resources/argocd-projects/argocd-projects.yaml` — onde declarar o AppProject do mesh.
