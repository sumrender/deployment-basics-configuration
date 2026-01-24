# Kubernetes Deployment Guide

## Quickstart

### Development Environment
```bash
kubectl apply -f k8s/dev/configmap.yaml
kubectl apply -f k8s/dev/mongo/
kubectl apply -f k8s/dev/elasticsearch/
kubectl apply -f k8s/dev/backend/
kubectl apply -f k8s/dev/frontend/
kubectl apply -f k8s/dev/ingress/
kubectl port-forward service/caddy-service 4444:80
```

### Staging Environment
```bash
kubectl apply -f k8s/staging/configmap.yaml
kubectl apply -f k8s/staging/mongo/
kubectl apply -f k8s/staging/elasticsearch/
kubectl apply -f k8s/staging/backend/
kubectl apply -f k8s/staging/frontend/
kubectl apply -f k8s/staging/ingress/
kubectl port-forward service/caddy-service 4444:80
```

### Production Environment
```bash
kubectl apply -f k8s/prod/configmap.yaml
kubectl apply -f k8s/prod/mongo/
kubectl apply -f k8s/prod/elasticsearch/
kubectl apply -f k8s/prod/backend/
kubectl apply -f k8s/prod/frontend/
kubectl apply -f k8s/prod/ingress/
kubectl port-forward service/caddy-service 4444:80
```

Delete everything
```bash
kubectl delete all --all
```

This directory contains Kubernetes manifests to deploy the Todo application.

## Namespace

**All resources are deployed to the `default` namespace.**

> **Note:** For production environments, consider creating a dedicated namespace (e.g., `todo-app`) for better isolation, resource quotas, and RBAC management. To use a custom namespace, add `namespace: <namespace-name>` to all manifest metadata sections and create the namespace first with `kubectl create namespace <namespace-name>`.

## Prerequisites

1. A running Kubernetes cluster (Minikube, Kind, or cloud provider)
2. `kubectl` configured to connect to your cluster
3. Docker images built and pushed to a registry:
   - `todo-backend:latest` (or environment-specific tags)
   - `todo-frontend:latest` (or environment-specific tags)

## Building and Pushing Images

Before deploying, you need to build and push the Docker images:

```bash
# Build backend image
cd backend
docker build -t todo-backend:latest .
# Tag for your registry (replace with your registry URL)
docker tag todo-backend:latest <your-registry>/todo-backend:latest
docker push <your-registry>/todo-backend:latest

# Build frontend image
cd ../frontend
docker build -t todo-frontend:latest .
# Tag for your registry
docker tag todo-frontend:latest <your-registry>/todo-frontend:latest
docker push <your-registry>/todo-frontend:latest
```

**Important:** Update the image references in `backend/deployment.yaml` and `frontend/deployment.yaml` for each environment (dev/staging/prod) to point to your registry if not using local images.

## Deployment Order

Deploy resources in the following order to respect dependencies:

```bash
# For dev environment
kubectl apply -f k8s/dev/configmap.yaml
kubectl apply -f k8s/dev/mongo/
kubectl apply -f k8s/dev/elasticsearch/

# Wait for databases to be ready

kubectl apply -f k8s/dev/backend/
kubectl apply -f k8s/dev/frontend/

kubectl apply -f k8s/dev/ingress/
```

```bash
# For prod environment
kubectl apply -f k8s/prod/configmap.yaml
kubectl apply -f k8s/prod/mongo/
kubectl apply -f k8s/prod/elasticsearch/

# Wait for databases to be ready

kubectl apply -f k8s/prod/backend/
kubectl apply -f k8s/prod/frontend/

kubectl apply -f k8s/prod/ingress/
```

## Quick Deploy (All at Once)

If you prefer to deploy everything at once:

```bash
# Dev environment
kubectl apply -f k8s/dev/

# Staging environment
kubectl apply -f k8s/staging/

# Production environment
kubectl apply -f k8s/prod/
```

Then wait for all pods to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=mongo --timeout=300s
kubectl wait --for=condition=ready pod -l app=elasticsearch --timeout=300s
kubectl wait --for=condition=ready pod -l app=backend --timeout=300s
kubectl wait --for=condition=ready pod -l app=frontend --timeout=300s
kubectl wait --for=condition=ready pod -l app=caddy --timeout=300s
```

## Accessing the Application

### Using Caddy Ingress

The application uses Caddy as a reverse proxy deployed as a standard Kubernetes component. This is platform-agnostic and doesn't require an ingress controller.

#### Local Development (HTTP)

1. Get the external IP or use port forwarding:
   ```bash
   # Check LoadBalancer external IP (may show as <pending> on local clusters)
   kubectl get service caddy-service
   
   # If using Docker Desktop or Minikube, you may need to use port forwarding:
   kubectl port-forward service/caddy-service 4444:80
   ```

2. Access the application:
   - Frontend: `http://localhost/`
   - Backend API: `http://localhost/api`

#### Cloud Deployment (HTTPS with Domain)

1. Update the Caddyfile in `k8s/<env>/ingress/configmap.yaml`:
   ```yaml
   data:
     Caddyfile: |
       # Replace http:// with your domain
       example.com {
           reverse_proxy /api/* backend-service:3001
           reverse_proxy /* frontend-service:3000
       }
   ```

2. Apply the updated ConfigMap:
   ```bash
   kubectl apply -f k8s/<env>/ingress/configmap.yaml
   kubectl rollout restart deployment/caddy-deployment
   ```

3. Caddy will automatically provision TLS certificates via Let's Encrypt.

4. Access the application:
   - Frontend: `https://example.com/`
   - Backend API: `https://example.com/api`

### Using Port Forwarding (Alternative)

If you prefer to access services directly without Caddy:

```bash
# Forward frontend
kubectl port-forward service/frontend-service 3000:3000

# Forward backend (in another terminal)
kubectl port-forward service/backend-service 3001:3001

# Forward MongoDB (if you need direct database access)
kubectl port-forward service/mongo-service 27017:27017

# Forward Elasticsearch (if you need direct access)
kubectl port-forward service/elasticsearch-service 9200:9200
```

Then access:
- Frontend: `http://localhost:3000`
- Backend API: `http://localhost:3001`
- MongoDB: `mongodb://localhost:27017`
- Elasticsearch: `http://localhost:9200`

## Verifying Deployment

Check the status of all resources:

```bash
# Check pods
kubectl get pods

# Check services
kubectl get services

# Check statefulsets
kubectl get statefulsets

# Check deployments
kubectl get deployments

# Check persistent volume claims
kubectl get pvc
```

## Troubleshooting

### View Pod Logs

```bash
# Backend logs
kubectl logs -l app=backend

# Frontend logs
kubectl logs -l app=frontend

# MongoDB logs
kubectl logs -l app=mongo

# Elasticsearch logs
kubectl logs -l app=elasticsearch

# Caddy logs
kubectl logs -l app=caddy
```

### Check Pod Status

```bash
# Describe a pod for detailed information
kubectl describe pod <pod-name>

# Check events
kubectl get events --sort-by='.lastTimestamp'
```

### Elasticsearch Requirements

Elasticsearch requires `vm.max_map_count` to be set to at least 262144. The StatefulSet includes an initContainer to set this, but if you encounter issues, you may need to set it on the node:

```bash
# On the Kubernetes node
sudo sysctl -w vm.max_map_count=262144
```

## Cleanup

To remove all resources:

```bash
# Dev environment
kubectl delete -f k8s/dev/

# Staging environment
kubectl delete -f k8s/staging/

# Production environment
kubectl delete -f k8s/prod/
```

Or delete individual components:

```bash
kubectl delete -f k8s/<env>/ingress/
kubectl delete -f k8s/<env>/frontend/
kubectl delete -f k8s/<env>/backend/
kubectl delete -f k8s/<env>/elasticsearch/
kubectl delete -f k8s/<env>/mongo/
kubectl delete -f k8s/<env>/configmap.yaml
```

**Note:** Deleting StatefulSets will also delete PersistentVolumeClaims by default. If you want to preserve data, delete the StatefulSets with `--cascade=orphan`:

```bash
kubectl delete statefulset mongo --cascade=orphan
kubectl delete statefulset elasticsearch --cascade=orphan
```

