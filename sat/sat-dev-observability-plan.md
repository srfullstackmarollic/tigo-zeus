# SAT dev — Plano de Observabilidade (Istio/Kiali + Elastic/Kibana)

Contexto levantado 2026-06-22/23. Decisões do cliente:
- Logs do SAT em **Elastic + Kibana próprio** (não Loki), **in-cluster via operador ECK**.
- SAT e GLX são **clusters isolados** → ELK do GLX não é reutilizável.
- Istio + Kiali: **greenfield** (não existe em SAT nem em GLX UAT — sem molde).
- Executar logs e mesh **em paralelo**.

## Estado atual (descoberto)
- **SAT dev**: 30+ apps no ns `argocd` (Deploy `-v1` / Svc `-v1-services` / container `app-container-…-v1`),
  1 container cada, **sem sidecar**. Logs hoje → Loki+Grafana+Promtail (ns `observability`). Sem Istio/Kiali/Kibana.
- **GLX UAT** (referência): também **sem Istio/Kiali**. Logging = `fluent-bit` DaemonSet → **ES externo**,
  com filtro Lua por allow-list de namespace, índice `fluent-bit-glx-uat-<ns>`. ES/Kibana fora do cluster.

## Molde reaproveitado do GLX
Só o **fluent-bit** (filtro `kubernetes` + Lua allow-list + índice por namespace). Destino muda: no SAT aponta
pro Elasticsearch in-cluster do ECK, não pro ELK externo.

---

## TRACK A — Elastic + Kibana (ECK) + fluent-bit

Namespaces: operador em `elastic-system`; ES/Kibana/fluent-bit em `logging`.

### Pré-requisitos a confirmar (pre-flight)
- StorageClass do nfs-client-provisioner (nome exato).
- IngressClass do rke2-ingress-nginx.
- Egress de internet do cluster (puxar CRDs/operator do download.elastic.co e imagens docker.elastic.co
  + cr.fluentbit.io). Se airgapped → espelhar imagens no registry interno.
- `vm.max_map_count`: contornado com `node.store.allow_mmap: false` no ES (evita sysctl no nó).

### Passos
1. Instalar CRDs + operador ECK (`elastic-system`).
2. `Elasticsearch` CR (1 nó dev, PVC NFS, heap 2g, allow_mmap=false).
3. `Kibana` CR + Ingress (host `kibana-dev-sat.tigo.com.pa`).
4. fluent-bit: SA + ClusterRole/Binding + ConfigMap (input tail + filter kubernetes + Lua allow-list `argocd`,
   índice `fluent-bit-sat-dev-<ns>`, output → `<es>-es-http.logging:9200` TLS, user `elastic`) + DaemonSet.
5. Verificar: índice criado, logs chegando, login no Kibana (secret `<es>-es-elastic-user`).

> Os manifests completos estão nos blocos `cat << EOF` entregues no chat.

---

## TRACK B — Istio + Kiali (greenfield)

Não há referência → instalação nova. Sequência staged, **sem big-bang**:

1. **Instalar control-plane** com `istioctl` (profile `default`), em `istio-system`. Sem mexer nos apps ainda.
2. **Kiali + addons** (Kiali apontando pro Prometheus já existente em `monitoring` — kube-prometheus-stack).
   Expor Kiali via Ingress (`kiali-dev-sat.tigo.com.pa`), auth via token/openid (avaliar Keycloak `keycloak-sit`).
3. **Habilitar injection por namespace** começando por 1–2 apps de baixo risco (canary), não no `argocd` inteiro
   de uma vez (o ns `argocd` hospeda o próprio ArgoCD + RabbitMQ — sidecar em tudo é arriscado).
   - Avaliar **mover os apps de negócio do ns `argocd` para um ns dedicado** (`sat-apps`) antes de ligar o mesh
     — já era anti-pattern apontado no `sat-dev-analysis.md`. Mesh é boa oportunidade pra isolar blast-radius.
4. **mTLS** em modo `PERMISSIVE` primeiro, depois `STRICT` por namespace.
5. **Gateways/VirtualServices** se for migrar o ingress nginx atual pro istio-ingressgateway (opcional; pode
   coexistir com o rke2-ingress-nginx no começo).

### Riscos no rke2
- `argocd` ns com sidecar pode quebrar o próprio ArgoCD / RabbitMQ (StatefulSet headless) → **excluir** esses
  workloads da injection (`sidecar.istio.io/inject: "false"`).
- CNI: rke2 usa Canal/Cilium — validar compatibilidade do istio-cni (ou usar init-container default).
- Recursos: control-plane + sidecars adicionam CPU/mem; cluster já tem CPU ocioso (ver D3), há folga.
- Egress de imagens `docker.io/istio/*` (ou mirror interno se airgapped).

### Decisões pendentes do Track B
- Auth do Kiali (anonymous dev vs Keycloak).
- Migrar apps pra ns dedicado antes do mesh? (recomendado)
- istio-ingressgateway substitui ou coexiste com rke2-ingress-nginx?
