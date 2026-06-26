#!/usr/bin/env bash
# Project Zeus — SAT compact collector. Minimal output, easy to copy from a locked terminal.
# Usage: ENV=dev bash zeus-sat-collect-compact.sh   (run on each bastion)
ENVNAME="${ENV:-unknown}"
NS=$(kubectl get deploy -A 2>/dev/null | grep -iE 'cr-app|iuc-|adminntt|digital-sale' | awk '{print $1}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "ZEUS env=$ENVNAME ns=$NS ctx=$(kubectl config current-context 2>/dev/null)"

echo "## DEPLOY name ready/desired reqCPU reqMEM limCPU limMEM"
kubectl get deploy -n "$NS" -o custom-columns='N:.metadata.name,RDY:.status.readyReplicas,DES:.spec.replicas,rC:.spec.template.spec.containers[0].resources.requests.cpu,rM:.spec.template.spec.containers[0].resources.requests.memory,lC:.spec.template.spec.containers[0].resources.limits.cpu,lM:.spec.template.spec.containers[0].resources.limits.memory' --no-headers 2>&1

echo "## HPA name min max cur-replicas targets"
kubectl get hpa -n "$NS" -o custom-columns='N:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,CUR:.status.currentReplicas' --no-headers 2>&1

echo "## TOP pod cpu mem"
kubectl top pods -n "$NS" --no-headers 2>&1 | awk '{print $1,$2,$3}'

echo "## PVC name status"
kubectl get pvc -n "$NS" --no-headers 2>&1 | awk '{print $1,$2}'

echo "## SVC name type ports"
kubectl get svc -n "$NS" --no-headers 2>&1 | awk '{print $1,$2,$5}'

echo "## ING host->service"
kubectl get ingress -n "$NS" -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"->"}{.http.paths[0].backend.service.name}{"\n"}{end}{end}' 2>&1

echo "## RABBIT queues (only non-idle: msgs>0 or consumers>0)"
RNS=$(kubectl get pods -A 2>/dev/null | grep -i rabbit | grep -i running | head -1 | awk '{print $1}')
RPOD=$(kubectl get pods -A 2>/dev/null | grep -i rabbit | grep -i running | head -1 | awk '{print $2}')
if [ -n "$RPOD" ]; then
  for V in $(kubectl exec -n "$RNS" "$RPOD" -- rabbitmqctl list_vhosts -q 2>/dev/null); do
    kubectl exec -n "$RNS" "$RPOD" -- rabbitmqctl list_queues -p "$V" -q name messages consumers 2>/dev/null \
      | awk -v v="$V" '($2+0>0)||($3+0>0){print v,$1,$2,$3}'
  done
else echo "rabbit-unreachable"; fi
echo "ZEUS-END"
