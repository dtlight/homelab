#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="argocd"

kubectl get namespace $NAMESPACE >/dev/null 2>&1 || \
  kubectl create namespace $NAMESPACE

kubectl apply -n $NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml