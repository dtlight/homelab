#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="traefik"
RELEASE="traefik"
KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

echo "... Adding Traefik Helm repo"
helm repo add traefik https://traefik.github.io/charts
helm repo update

echo "... Creating namespace (if needed)"
kubectl --kubeconfig=$KUBECONFIG get namespace ${NAMESPACE} >/dev/null 2>&1 || \
kubectl --kubeconfig=$KUBECONFIG create namespace ${NAMESPACE}

echo "... Installing / upgrading Traefik"
helm upgrade --install ${RELEASE} traefik/traefik \
  --namespace ${NAMESPACE} \
  --values values.yaml \
  --kubeconfig=$KUBECONFIG

echo "... Waiting for Traefik to be ready"
kubectl --kubeconfig=$KUBECONFIG rollout status deployment/${RELEASE} -n ${NAMESPACE}

kubectl get pods -n traefik

