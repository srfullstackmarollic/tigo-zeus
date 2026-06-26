#!/usr/bin/env bash
# Project Zeus — SAT dev · Istio (ambient) + Kiali · Fase 0 pre-flight (READ-ONLY)
# Corre no bastion Wallix com kubectl já apontando para tocpait-sat-dev.
# Uso:  bash zeus-sat-istio-preflight.sh
# Não muda nada no cluster. Envia o output de volta para anexar a outs-cmd.txt.

OUT="/tmp/zeus-sat-dev-istio-preflight-$(date '+%Y%m%d-%H%M%S').txt"
exec > >(tee "$OUT") 2>&1
S(){ echo; echo "=== $* ==="; }

S "META"
echo "date=$(date '+%Y-%m-%d %H:%M:%S') ctx=$(kubectl config current-context 2>&1) host=$(hostname)"

# 1) Prometheus / Grafana / monitoring já existentes? -> decide reaproveitar vs provisionar
S "1. PROMETHEUS / GRAFANA / MONITORING (existe?)"
kubectl get ns 2>&1
echo "--- pods de observabilidade ---"
kubectl get pods -A 2>/dev/null | grep -iE 'promet|grafana|monitor|observab|victoria|thanos' || echo "NENHUM encontrado"
echo "--- services :9090 candidatos a prometheus ---"
kubectl get svc -A 2>/dev/null | grep -iE 'promet|9090' || echo "nenhum svc prometheus aparente"

# 2) Nó do ArgoCD -> nodeSelector/affinity do Kiali (já usamos podAffinity ao argocd-server,
#    mas registramos o nó para referência)
S "2. NO DO ARGOCD (argocd-server)"
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-server -o wide 2>&1

# 3) CNI do RKE2 -> compatibilidade istio-cni / ztunnel (ambient) e paths de CNI
S "3. CNI DO RKE2 (compat ambient + paths)"
kubectl get pods -n kube-system 2>/dev/null | grep -iE 'canal|calico|cilium|flannel|multus' || echo "sem pods CNI óbvios em kube-system"
kubectl get installation -A 2>/dev/null || echo "sem CRD 'installation' (não é Calico operator)"
echo "--- caminhos de CNI no nó (rodar no nó se kubectl não bastar) ---"
echo "RKE2 normalmente usa  bin=/opt/cni/bin  conf=/etc/cni/net.d  (validar!)"
ls -la /opt/cni/bin 2>/dev/null | head || echo "(/opt/cni/bin não visível deste host)"
ls -la /etc/cni/net.d 2>/dev/null || echo "(/etc/cni/net.d não visível deste host)"
ls -la /var/lib/rancher/rke2/agent/cni 2>/dev/null || echo "(path rke2 agent/cni não visível deste host)"

# 4) StorageClass / IngressClass
S "4. STORAGECLASS"
kubectl get sc 2>&1
S "4b. INGRESSCLASS (confirmar nginx)"
kubectl get ingressclass 2>&1

# 5) Egress de imagens (istio + kiali). Testa pull num pod efêmero descartável.
S "5. EGRESS DE IMAGENS (docker.io/istio, quay.io/kiali)"
echo "Validar se o cluster puxa as imagens abaixo (ou se precisa mirror interno/airgap):"
echo "  docker.io/istio/pilot   docker.io/istio/install-cni   docker.io/istio/ztunnel   docker.io/istio/proxyv2"
echo "  quay.io/kiali/kiali"
echo "--- registries já usados no cluster (pistas de mirror) ---"
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
  | sort -u | grep -iE 'tigopa|registry|harbor|quay|docker.io' | head -30 || echo "n/d"

# 6) Versão do K8s/RKE2 -> fixar versão compatível do Istio
S "6. VERSAO K8S / RKE2"
kubectl version 2>&1 | grep -iE 'server|version' || kubectl version --short 2>&1
kubectl get nodes -o wide 2>&1

# 7) Estado atual de Istio (deve estar VAZIO antes da Fase 2)
S "7. ISTIO JA INSTALADO? (deve ser vazio)"
kubectl get ns istio-system 2>&1
kubectl get pods -n istio-system 2>&1
kubectl get crd 2>/dev/null | grep -i istio || echo "nenhuma CRD istio (esperado)"

S "DONE"
echo "saved to $OUT"
