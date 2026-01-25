# Dummy Configuration

This directory contains Terraform and Kubernetes configuration for deploying the Todo application stack on EC2 with K3s.

## Structure

- `k8s/` - Kubernetes manifests organized by environment (dev, staging)
- `tf/` - Terraform configurations for EC2 + K3s infrastructure
- `argocd/` - Argo CD GitOps configuration and bootstrap scripts

## Environments

Two environments are configured:
- **dev** - Development environment
- **staging** - Staging environment

Both environments share the same infrastructure architecture but differ in the container images used for frontend and backend deployments.

## Quick Start

### Deploy Development Environment

```bash
cd dummy-configuration/tf/ec2-k3s/dev
terraform init
terraform apply
```

### Deploy Staging Environment

```bash
cd dummy-configuration/tf/ec2-k3s/staging
terraform init
terraform apply
```

## SSH Access

After deployment, Terraform will output the SSH command. The private key is saved as `ec2-key.pem` in the respective environment directory.

Example:
```bash
ssh -i ec2-key.pem ubuntu@<EC2_PUBLIC_IP>
```

## Changing Container Images

To change the container images for frontend or backend in a specific environment:

1. Edit the deployment file:
   - Dev: `k8s/dev/frontend/deployment.yaml` or `k8s/dev/backend/deployment.yaml`
   - Staging: `k8s/staging/frontend/deployment.yaml` or `k8s/staging/backend/deployment.yaml`

2. Update the `image` field in the container specification

3. Apply the changes:
   ```bash
   kubectl apply -f k8s/<env>/frontend/deployment.yaml
   kubectl apply -f k8s/<env>/backend/deployment.yaml
   ```

## Accessing the Application

After deployment completes, access the application at:
- `http://<EC2_PUBLIC_IP>/`

The Terraform output will display the exact URL after `terraform apply` completes.

## Terraform State

Each environment maintains its own local Terraform state file in its respective directory. This ensures complete isolation between dev and staging environments.

## Useful commands

- SSH into a server: `ssh -i "ec2-key.pem" ubuntu@43.204.96.143`

- Logs on servers: `cat /var/log/cloud-init-output.log`

- ArgoCD password (run on master node where argocd is running): 
```
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```
