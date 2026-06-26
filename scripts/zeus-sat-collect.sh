#!/usr/bin/env bash
# Project Zeus — SAT collector (run once per env: dev, then uat)
# Usage: ENV=dev bash zeus-sat-collect.sh   /   ENV=uat bash zeus-sat-collect.sh
# Assumes kubectl is already pointed at the right cluster context.

ENVNAME="${ENV:-unknown}"
OUT="/tmp/zeus-sat-${ENVNAME}-$(date '+%Y%m%d-%H%M%S').txt"
exec > >(tee "$OUT") 2>&1
S(){ echo; echo "=== $* ==="; }

S "META"
echo "env=$ENVNAME date=$(date '+%Y-%m-%d %H:%M:%S') ctx=$(kubectl config current-context 2>&1) host=$(hostname)"

# --- discover the namespace(s) holding SAT workloads (cr-*, iuc-*, adminntt-*, digital-sale-*, service-auth) ---
S "NS_GUESS"
kubectl get deploy -A 2>/dev/null \
  | grep -iE 'cr-app|cr-service|iuc-|adminntt|digital-sale|service-auth' \
  | awk '{print $1}' | sort | uniq -c | sort -rn
NS=$(kubectl get deploy -A 2>/dev/null | grep -iE 'cr-app|iuc-|adminntt|digital-sale' | awk '{print $1}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "PICKED_NS=$NS"

S "DEPLOYMENTS (replicas desired/ready)"
kubectl get deploy -n "$NS" -o wide 2>&1

S "HPA_LIVE"
kubectl get hpa -n "$NS" 2>&1

S "PODS"
kubectl get pods -n "$NS" -o wide 2>&1

S "POD_TOP (cpu/mem actual)"
kubectl top pods -n "$NS" 2>&1 | sort -k3 -h || echo "metrics-server unavailable"

S "RESOURCES_REQLIM (per deploy)"
kubectl get deploy -n "$NS" -o custom-columns='NAME:.metadata.name,REQ_CPU:.spec.template.spec.containers[0].resources.requests.cpu,REQ_MEM:.spec.template.spec.containers[0].resources.requests.memory,LIM_CPU:.spec.template.spec.containers[0].resources.limits.cpu,LIM_MEM:.spec.template.spec.containers[0].resources.limits.memory' 2>&1

S "PVC (stateful / blocks horizontal scale)"
kubectl get pvc -n "$NS" 2>&1

S "SERVICES"
kubectl get svc -n "$NS" -o wide 2>&1

S "INGRESS (who is reachable from outside / through what host)"
kubectl get ingress -n "$NS" -o wide 2>&1

S "RABBIT_PODS"
kubectl get pods -A 2>&1 | grep -i rabbit | grep -i running || echo "none"
RNS=$(kubectl get pods -A 2>/dev/null | grep -i rabbit | grep -i running | head -1 | awk '{print $1}')
RPOD=$(kubectl get pods -A 2>/dev/null | grep -i rabbit | grep -i running | head -1 | awk '{print $2}')
echo "rabbit ns=$RNS pod=$RPOD"

S "RABBIT_VHOSTS"
[ -n "$RPOD" ] && kubectl exec -n "$RNS" "$RPOD" -- rabbitmqctl list_vhosts 2>&1 || echo "skip"

S "RABBIT_QUEUES_ALL (name messages consumers state) — KEDA inputs"
if [ -n "$RPOD" ]; then
  for V in $(kubectl exec -n "$RNS" "$RPOD" -- rabbitmqctl list_vhosts -q 2>/dev/null); do
    echo "--- vhost: $V ---"
    kubectl exec -n "$RNS" "$RPOD" -- rabbitmqctl list_queues -p "$V" name messages consumers state 2>&1
  done
else echo "skip"; fi

S "DONE"
echo "saved to $OUT"
