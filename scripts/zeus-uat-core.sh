NS=$(kubectl get deploy -A | grep -m1 cr-app-backend | awk '{print $1}')
F="cr-|iuc-|adminntt|digital|service-auth"
echo "ns=$NS"
echo ===DEPLOY===; kubectl get deploy  -n $NS | grep -iE "$F"
echo ===HPA===;    kubectl get hpa     -n $NS | grep -iE "$F"
echo ===TOP===;    kubectl top pods    -n $NS | grep -iE "$F"
echo ===PVC===;    kubectl get pvc     -n $NS | grep -iE "$F"
echo ===SVC===;    kubectl get svc     -n $NS | grep -iE "$F"
echo ===ING===;    kubectl get ingress -n $NS | grep -iE "$F"
