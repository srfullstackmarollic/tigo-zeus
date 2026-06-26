NS=$(kubectl get deploy -A | grep -m1 cr-app-backend | awk '{print $1}')
echo "== getpayments logs =="
kubectl logs -n $NS deploy/cr-service-getpayments-v1 --tail=15
echo "== getpayments /data =="
kubectl exec -n $NS deploy/cr-service-getpayments-v1 -- ls -la /data
echo "== consumer-sms logs =="
kubectl logs -n $NS deploy/adminntt-service-consumer-sms-v1 --tail=25
