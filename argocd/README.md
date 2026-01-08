# ArgoCD Local Setup (Dev)

## Prerequisites
Local Kubernetes cluster (kind/minikube/k3d)

## Installation

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for pods to be ready:
```bash
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

## Access

Port-forward ArgoCD server:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access UI: https://localhost:8080

Default credentials:
- Username: `admin`
- Password: Get with `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

## Deploy Dev Application

```bash
kubectl apply -f dev/application.yaml
```

## Quick Reference

Get admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

Sync application manually:
```bash
kubectl patch application platform-dev -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

Check application status:
```bash
kubectl get application platform-dev -n argocd
```

