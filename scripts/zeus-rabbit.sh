RNS=$(kubectl get pods -A | grep -i rabbit | grep Running | head -1 | awk '{print $1}')
RPOD=$(kubectl get pods -A | grep -i rabbit | grep Running | head -1 | awk '{print $2}')
echo "rabbit ns=$RNS pod=$RPOD"
for V in $(kubectl exec -n $RNS $RPOD -- rabbitmqctl list_vhosts -q); do
  echo "== vhost $V =="
  kubectl exec -n $RNS $RPOD -- rabbitmqctl list_queues -p "$V" name messages consumers
done
