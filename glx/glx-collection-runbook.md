# GLX / SAT — Collection Runbook (read-only, internal)

Internal tooling notes for reproducing the platform/application mapping. **Not part of the client report.**

## Access (RKE2, on a master node via bastion)

`/usr/bin/kubectl` may be non-executable for the user; use the RKE2-bundled binary. Fix the kubeconfig (it ships `600 root`) and alias:

```bash
sudo cp /etc/rancher/rke2/rke2.yaml "$HOME/rke2.yaml" && sudo chown "$USER" "$HOME/rke2.yaml" && chmod 600 "$HOME/rke2.yaml"
alias k='/var/lib/rancher/rke2/bin/kubectl --kubeconfig=$HOME/rke2.yaml'
k get nodes; hostname
```

> SIT/UAT often work with plain `kubectl` after `export KUBECONFIG="$HOME/rke2.yaml"`. PROD needed the RKE2 binary + alias.

## Commands (all read-only)

| Goal | Command |
|---|---|
| Cluster | `k get nodes` ; `k get ns --show-labels` |
| Apps | `k -n glx get deploy` ; `k -n glx get pods` |
| Istio version | `k -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| Istio CRs | `k -n glx get gateway,virtualservice,destinationrule,peerauthentication,authorizationpolicy,sidecar` |
| Kiali | `k get deploy,svc -A \| grep -i kiali` |
| HPA | `k get hpa -A` |
| Monitoring | `k -n monitoring get deploy,sts` |
| Ingress | `k get ingress -A` |
| Resources | `k -n glx get deploy -o 'custom-columns=NAME:.metadata.name,CPUREQ:.spec.template.spec.containers[0].resources.requests.cpu,CPULIM:.spec.template.spec.containers[0].resources.limits.cpu,MEMREQ:.spec.template.spec.containers[0].resources.requests.memory,MEMLIM:.spec.template.spec.containers[0].resources.limits.memory'` |
| Images | `k -n glx get deploy -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'` |

## Incident triage (image pull failures)

```bash
# list pods with image-pull problems
k -n glx get pods | grep -iE 'ImagePull|ErrImage'
# exact image + reason for a given pod
k -n glx describe pod <pod> | grep -iE 'Image:|Reason:|Failed|ImagePull|ErrImage|manifest|not found|denied|unauthorized' | head -20
```

## Notes

- SAT dev: apps live in namespace `argocd` (not `glx`); container name `app-container-<app>-v1`; single ingress host `k8s-dev-sat.tigo.com.pa`. Adapt `-n glx` → `-n argocd` and container index accordingly.
- Paste-safe: prefer single-line `custom-columns` over heredocs (avoids terminal line-wrap mangling).
