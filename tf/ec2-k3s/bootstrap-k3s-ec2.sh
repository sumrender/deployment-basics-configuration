#!/bin/bash
set -euo pipefail

################################################################################
# EC2 k3s Bootstrap Script
# 
# This script sets up a single-node k3s cluster on Ubuntu EC2, installs ArgoCD,
# and configures ArgoCD to deploy the Todo application stack (MongoDB, Elasticsearch,
# Backend, Frontend, Caddy) via GitOps.
#
# Usage:
#   sudo ./bootstrap-k3s-ec2.sh
#
# Environment Variables:
#   - K8S_ENV: Kubernetes environment name (dev, staging, etc.) - determines which ArgoCD Application to apply
#   - REPO_URL: GitHub repository URL to clone (default: https://github.com/sumrender/deployment-basics-configuration.git)
#   - REPO_BRANCH: GitHub repository branch to clone (default: main)
#   - ARGOCD_ADMIN_PASSWORD: ArgoCD admin password (required)
#
# Prerequisites:
#   - Ubuntu EC2 instance (tested on 20.04/22.04)
#   - Run with root or sudo privileges
#   - EC2 Security Group must allow:
#     - Port 22 (SSH)
#     - Port 80 (HTTP for Caddy)
#     - Port 443 (HTTPS for Caddy, optional if using HTTP only)
#     - Port 3333 (ArgoCD UI)
#
# Important Notes:
#   - This script does NOT configure host firewall (ufw). You must restrict
#     access via EC2 Security Group rules to enforce "Caddy only" exposure.
#   - The script expects images to be available in a registry:
#     - sumrenders/todo-backend:latest
#     - sumrenders/todo-frontend:latest
#   - ArgoCD will automatically deploy Kubernetes manifests from Git repository.
#
# After completion:
#   - Verify with: kubectl get pods,svc
#   - Access app at: http://<EC2_PUBLIC_IP>/
#   - Access ArgoCD UI at: http://<EC2_PUBLIC_IP>:3333 (username: admin)
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log file configuration
LOG_DIR="/var/log/bootstrap-k3s-ec2"
LOG_FILE=""
LOG_FILE_LATEST=""

# Initialize log directory and file
init_log_file() {
    # Generate timestamp when log file is actually created
    local LOG_FILE_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    
    # Try to create log directory in /var/log, fallback to /tmp if it fails
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_DIR="/tmp/bootstrap-k3s-ec2"
        LOG_FILE="${LOG_DIR}/bootstrap-${LOG_FILE_TIMESTAMP}.log"
        LOG_FILE_LATEST="${LOG_DIR}/latest.log"
        mkdir -p "$LOG_DIR" || {
            echo "Failed to create log directory, using /tmp"
            LOG_DIR="/tmp"
            LOG_FILE="/tmp/bootstrap-k3s-ec2-${LOG_FILE_TIMESTAMP}.log"
            LOG_FILE_LATEST="/tmp/bootstrap-k3s-ec2-latest.log"
        }
    else
        # Set log file paths for /var/log location
        LOG_FILE="${LOG_DIR}/bootstrap-${LOG_FILE_TIMESTAMP}.log"
        LOG_FILE_LATEST="${LOG_DIR}/latest.log"
    fi
    
    # Create log file with header
    {
        echo "================================================================================"
        echo "Bootstrap k3s EC2 Script Log"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================================"
        echo ""
    } > "$LOG_FILE" 2>/dev/null || true
    
    # Create symlink to latest log
    ln -sf "$LOG_FILE" "$LOG_FILE_LATEST" 2>/dev/null || true
    
    # Set permissions
    chmod 644 "$LOG_FILE" 2>/dev/null || true
}

# Configuration (can be overridden via environment variables)
REPO_URL="${REPO_URL:-https://github.com/sumrender/deployment-basics-configuration.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/tmp/deployment-basics-configuration}"
K3S_INSTALL_SCRIPT="${K3S_INSTALL_SCRIPT:-https://get.k3s.io}"
K8S_ENV="${K8S_ENV:-dev}"

# Helper functions
log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[INFO]${NC} $message"
    echo "[${timestamp}] [INFO] $message" >> "$LOG_FILE" 2>/dev/null || true
}

log_warn() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARN]${NC} $message"
    echo "[${timestamp}] [WARN] $message" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} $message"
    echo "[${timestamp}] [ERROR] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Logging functions for file-only logging
log_to_file() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] $message" >> "$LOG_FILE" 2>/dev/null || true
}

log_step_start() {
    local step_name="$1"
    log_info "Starting step: ${step_name}"
    log_to_file "STEP" "Starting: ${step_name}"
}

log_step_end() {
    local step_name="$1"
    log_info "Completed step: ${step_name}"
    log_to_file "STEP" "Completed: ${step_name}"
}

log_step_error() {
    local step_name="$1"
    local error_details="$2"
    local exit_code="${3:-}"
    log_error "Step '${step_name}' failed: ${error_details}"
    if [[ -n "$exit_code" ]]; then
        log_to_file "ERROR" "Step '${step_name}' failed: ${error_details} (exit code: ${exit_code})"
    else
        log_to_file "ERROR" "Step '${step_name}' failed: ${error_details}"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script is designed for Ubuntu."
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_warn "This script is designed for Ubuntu. Detected: $ID"
        # Check if running in non-interactive mode (e.g., via cloud-init/user_data)
        if [[ -n "${NONINTERACTIVE:-}" ]] || [[ ! -t 0 ]]; then
            log_warn "Running in non-interactive mode. Continuing anyway..."
        else
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
}

# Step 1: Install prerequisites
install_prerequisites() {
    log_step_start "install_prerequisites"
    log_info "Installing prerequisites (curl, git)..."
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update -qq && apt-get install -y -qq curl git > /dev/null; then
        log_info "Prerequisites installed"
        log_step_end "install_prerequisites"
    else
        log_step_error "install_prerequisites" "Failed to install prerequisites" "$?"
        exit 1
    fi
}

# Step 2: Set Elasticsearch kernel parameter
set_es_kernel_param() {
    log_step_start "set_es_kernel_param"
    log_info "Setting vm.max_map_count for Elasticsearch..."
    if sysctl -w vm.max_map_count=262144 > /dev/null; then
        # Make it persistent across reboots
        if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf
            log_info "Added vm.max_map_count to /etc/sysctl.conf"
        else
            log_info "vm.max_map_count already in /etc/sysctl.conf"
        fi
        log_step_end "set_es_kernel_param"
    else
        log_step_error "set_es_kernel_param" "Failed to set vm.max_map_count" "$?"
        exit 1
    fi
}

# Step 3: Install k3s
install_k3s() {
    log_step_start "install_k3s"
    if command -v k3s &> /dev/null; then
        log_warn "k3s appears to be already installed. Skipping installation."
        log_info "To reinstall, uninstall k3s first: /usr/local/bin/k3s-uninstall.sh"
        log_step_end "install_k3s"
        return
    fi
    
    log_info "Installing k3s (single-node cluster)..."
    log_to_file "INFO" "Executing: curl -sfL ${K3S_INSTALL_SCRIPT} | sh -"
    if curl -sfL "$K3S_INSTALL_SCRIPT" | sh -; then
        log_to_file "INFO" "k3s installation command completed successfully"
    else
        log_step_error "install_k3s" "k3s installation command failed" "$?"
        exit 1
    fi
    
    # Wait for k3s to be ready
    log_info "Waiting for k3s to be ready..."
    timeout=60
    elapsed=0
    while ! k3s kubectl get nodes &> /dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_step_error "install_k3s" "k3s failed to start within ${timeout}s" "1"
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log_info "k3s installed and ready"
    
    # Verify ServiceLB is enabled (it's enabled by default)
    log_info "k3s ServiceLB (LoadBalancer) is enabled by default"
    log_step_end "install_k3s"
}

# Step 3b: Configure kubeconfig for a non-root user (so `kubectl` works without sudo)
configure_kubeconfig() {
    log_step_start "configure_kubeconfig"
    local kubeconfig_src="/etc/rancher/k3s/k3s.yaml"
    local target_user="${SUDO_USER:-ubuntu}"

    if [[ ! -f "$kubeconfig_src" ]]; then
        log_warn "kubeconfig not found at ${kubeconfig_src}; skipping kubeconfig setup"
        log_step_end "configure_kubeconfig"
        return
    fi

    if ! id "$target_user" &>/dev/null; then
        log_warn "User '${target_user}' does not exist; skipping kubeconfig setup"
        log_step_end "configure_kubeconfig"
        return
    fi

    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        log_warn "Cannot determine home for user '${target_user}'; skipping kubeconfig setup"
        log_step_end "configure_kubeconfig"
        return
    fi

    log_info "Configuring kubeconfig for user '${target_user}'..."
    if mkdir -p "${target_home}/.kube" && \
       cp -f "$kubeconfig_src" "${target_home}/.kube/config" && \
       chown -R "${target_user}:${target_user}" "${target_home}/.kube" && \
       chmod 700 "${target_home}/.kube" && \
       chmod 600 "${target_home}/.kube/config"; then
        log_info "kubeconfig written to ${target_home}/.kube/config (use: kubectl get pods)"
        log_step_end "configure_kubeconfig"
    else
        log_step_error "configure_kubeconfig" "Failed to configure kubeconfig" "$?"
        exit 1
    fi
}

# Step 3c: Persist KUBECONFIG environment variable for the user
persist_kubeconfig_env() {
    log_step_start "persist_kubeconfig_env"
    local target_user="${SUDO_USER:-ubuntu}"

    if ! id "$target_user" &>/dev/null; then
        log_warn "User '${target_user}' does not exist; skipping KUBECONFIG persistence"
        log_step_end "persist_kubeconfig_env"
        return
    fi

    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        log_warn "Cannot determine home for user '${target_user}'; skipping KUBECONFIG persistence"
        log_step_end "persist_kubeconfig_env"
        return
    fi

    local kubeconfig_path="${target_home}/.kube/config"
    if [[ ! -f "$kubeconfig_path" ]]; then
        log_warn "kubeconfig not found at ${kubeconfig_path}; skipping KUBECONFIG persistence"
        log_step_end "persist_kubeconfig_env"
        return
    fi

    log_info "Persisting KUBECONFIG for user '${target_user}'..."

    # Determine which profile file to use (prefer .bashrc, fallback to .profile)
    local profile_file
    if [[ -f "${target_home}/.bashrc" ]]; then
        profile_file="${target_home}/.bashrc"
    elif [[ -f "${target_home}/.profile" ]]; then
        profile_file="${target_home}/.profile"
    else
        # Create .bashrc if neither exists
        profile_file="${target_home}/.bashrc"
        touch "$profile_file"
        chown "${target_user}:${target_user}" "$profile_file"
    fi

    # Check if KUBECONFIG export already exists (idempotent)
    local marker="# KUBECONFIG for k3s (added by bootstrap-k3s-ec2.sh)"
    if grep -q "$marker" "$profile_file" 2>/dev/null; then
        log_info "KUBECONFIG export already exists in ${profile_file}, skipping"
        log_step_end "persist_kubeconfig_env"
        return
    fi

    # Append the KUBECONFIG export with a marker
    {
        echo ""
        echo "$marker"
        echo "export KUBECONFIG=\"${kubeconfig_path}\""
    } >> "$profile_file"

    chown "${target_user}:${target_user}" "$profile_file"
    log_info "KUBECONFIG export added to ${profile_file}"
    log_step_end "persist_kubeconfig_env"
}

# Step 4: Clone repository
clone_repo() {
    log_step_start "clone_repo"
    log_info "Cloning repository: $REPO_URL (branch: $REPO_BRANCH)"
    log_to_file "INFO" "Executing: git clone/pull for ${REPO_URL} branch ${REPO_BRANCH}"
    
    if [[ -d "$REPO_DIR" ]]; then
        log_warn "Repository directory already exists: $REPO_DIR"
        log_info "Pulling latest changes..."
        cd "$REPO_DIR"
        if git fetch origin && \
           (git checkout "$REPO_BRANCH" 2>/dev/null || true) && \
           git pull origin "$REPO_BRANCH"; then
            log_info "Repository updated successfully"
        else
            log_step_error "clone_repo" "Failed to pull latest changes" "$?"
            exit 1
        fi
    else
        if git clone -b "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"; then
            log_info "Repository cloned successfully"
        else
            log_step_error "clone_repo" "Failed to clone repository" "$?"
            exit 1
        fi
    fi
    
    log_info "Repository ready at: $REPO_DIR"
    log_step_end "clone_repo"
}

# Step 5: Set ArgoCD admin password
set_argocd_password() {
    log_step_start "set_argocd_password"
    local argocd_password="${ARGOCD_ADMIN_PASSWORD:-}"
    
    if [[ -z "$argocd_password" ]]; then
        log_step_error "set_argocd_password" "ARGOCD_ADMIN_PASSWORD environment variable is required but not set" "1"
        exit 1
    fi
    
    log_info "Setting ArgoCD admin password..."
    
    # Create namespace first
    log_to_file "INFO" "Executing: k3s kubectl create namespace argocd"
    if k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f -; then
        log_to_file "INFO" "ArgoCD namespace created/verified"
    else
        log_step_error "set_argocd_password" "Failed to create argocd namespace" "$?"
        exit 1
    fi
    
    # Install apache2-utils for htpasswd (if not already installed)
    if ! command -v htpasswd &> /dev/null; then
        log_info "Installing apache2-utils for password hashing..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y -qq apache2-utils > /dev/null; then
            log_to_file "INFO" "apache2-utils installed"
        else
            log_step_error "set_argocd_password" "Failed to install apache2-utils" "$?"
            exit 1
        fi
    fi
    
    # Generate bcrypt hash
    # Note: ArgoCD uses $2a$ format, htpasswd generates $2y$, so we convert
    log_to_file "INFO" "Generating bcrypt hash for password"
    local bcrypt_hash
    if bcrypt_hash=$(htpasswd -bnBC 10 "" "$argocd_password" | tr -d ':\n' | sed 's/$2y/$2a/'); then
        log_to_file "INFO" "Password hash generated successfully"
    else
        log_step_error "set_argocd_password" "Failed to generate password hash" "$?"
        exit 1
    fi
    
    # Create the secret (ArgoCD will use this if it exists)
    log_to_file "INFO" "Executing: k3s kubectl create secret argocd-initial-admin-secret"
    if k3s kubectl create secret generic argocd-initial-admin-secret \
        --from-literal=password="$bcrypt_hash" \
        -n argocd \
        --dry-run=client -o yaml | k3s kubectl apply -f -; then
        log_info "ArgoCD admin password secret created"
        log_step_end "set_argocd_password"
    else
        log_step_error "set_argocd_password" "Failed to create ArgoCD password secret" "$?"
        exit 1
    fi
}

# Step 6: Install ArgoCD
install_argocd() {
    log_step_start "install_argocd"
    log_info "Installing ArgoCD..."
    
    # Create namespace (if not already created)
    log_to_file "INFO" "Executing: k3s kubectl create namespace argocd"
    if k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f -; then
        log_to_file "INFO" "ArgoCD namespace created/verified"
    else
        log_step_error "install_argocd" "Failed to create argocd namespace" "$?"
        exit 1
    fi
    
    # Install ArgoCD
    log_to_file "INFO" "Executing: k3s kubectl apply ArgoCD manifests"
    if k3s kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml; then
        log_to_file "INFO" "ArgoCD manifests applied successfully"
    else
        log_step_error "install_argocd" "Failed to apply ArgoCD manifests" "$?"
        exit 1
    fi
    
    # Wait for ArgoCD server to be ready
    log_info "Waiting for ArgoCD to be ready (this may take 2-3 minutes)..."
    log_to_file "INFO" "Executing: k3s kubectl wait for argocd-server deployment"
    if k3s kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s; then
        log_info "ArgoCD installed and ready"
        log_step_end "install_argocd"
    else
        log_step_error "install_argocd" "ArgoCD server failed to start within timeout" "$?"
        exit 1
    fi
}

# Step 7: Expose ArgoCD UI on port 3333
expose_argocd_ui() {
    log_step_start "expose_argocd_ui"
    log_info "Exposing ArgoCD UI on port 3333 (NodePort)..."
    
    # Patch ArgoCD server service to NodePort type with port 3333
    log_to_file "INFO" "Executing: k3s kubectl patch svc argocd-server to NodePort"
    if k3s kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":3333,"protocol":"TCP"}]}}'; then
        log_to_file "INFO" "ArgoCD service patched successfully"
    else
        log_step_error "expose_argocd_ui" "Failed to patch ArgoCD server service" "$?"
        exit 1
    fi
    
    # Verify service is updated
    local service_type
    service_type=$(k3s kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
    
    if [[ "$service_type" == "NodePort" ]]; then
        log_info "ArgoCD UI exposed on port 3333"
        log_step_end "expose_argocd_ui"
    else
        log_warn "ArgoCD service type is ${service_type}, expected NodePort"
        log_step_end "expose_argocd_ui"
    fi
}

# Step 8: Apply ArgoCD Application
apply_argocd_application() {
    log_step_start "apply_argocd_application"
    log_info "Applying ArgoCD Application for environment: ${K8S_ENV}"
    
    cd "$REPO_DIR"
    
    # Validate K8S_ENV
    local argocd_app_path="argocd/${K8S_ENV}/application.yaml"
    if [[ ! -f "$argocd_app_path" ]]; then
        log_step_error "apply_argocd_application" "ArgoCD Application manifest not found: ${argocd_app_path}" "1"
        log_error "K8S_ENV is set to: ${K8S_ENV}"
        log_error "Available environments: $(ls -d argocd/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || echo 'none found')"
        exit 1
    fi
    
    # Use the user kubeconfig (same logic as configure_kubeconfig)
    local target_user="${SUDO_USER:-ubuntu}"
    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -n "$target_home" && -f "${target_home}/.kube/config" ]]; then
        export KUBECONFIG="${target_home}/.kube/config"
    else
        # Fallback to root kubeconfig if user config doesn't exist
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi
    
    # Apply ArgoCD Application
    log_to_file "INFO" "Executing: k3s kubectl apply -f ${argocd_app_path}"
    if k3s kubectl apply -f "$argocd_app_path"; then
        log_to_file "INFO" "ArgoCD Application applied successfully"
    else
        log_step_error "apply_argocd_application" "Failed to apply ArgoCD Application" "$?"
        exit 1
    fi
    
    # Wait for Application CRD to be established
    log_info "Waiting for ArgoCD Application CRD to be established..."
    log_to_file "INFO" "Executing: k3s kubectl wait for applications.argoproj.io CRD"
    if k3s kubectl wait --for=condition=established crd applications.argoproj.io --timeout=60s; then
        log_to_file "INFO" "Application CRD established"
    else
        log_warn "Application CRD not established within timeout, continuing anyway..."
    fi
    
    log_info "ArgoCD Application applied"
    log_step_end "apply_argocd_application"
}

# Step 9: Wait for ArgoCD sync
wait_for_argocd_sync() {
    log_step_start "wait_for_argocd_sync"
    log_info "Waiting for ArgoCD Application 'platform-${K8S_ENV}' to sync..."
    
    # Use the user kubeconfig (same logic as configure_kubeconfig)
    local target_user="${SUDO_USER:-ubuntu}"
    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -n "$target_home" && -f "${target_home}/.kube/config" ]]; then
        export KUBECONFIG="${target_home}/.kube/config"
    else
        # Fallback to root kubeconfig if user config doesn't exist
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi
    
    local app_name="platform-${K8S_ENV}"
    local timeout=600  # 10 minutes
    local elapsed=0
    
    log_to_file "INFO" "Waiting for ArgoCD Application '${app_name}' to sync (timeout: ${timeout}s)"
    while true; do
        local status
        status=$(k3s kubectl get application "$app_name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        log_to_file "INFO" "ArgoCD Application sync status: ${status} (elapsed: ${elapsed}s)"
        
        if [[ "$status" == "Synced" ]]; then
            log_info "ArgoCD Application synced successfully!"
            log_step_end "wait_for_argocd_sync"
            break
        fi
        
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "ArgoCD sync timeout (${timeout}s). Current status: ${status}"
            log_warn "Check status manually: kubectl get application -n argocd"
            log_step_end "wait_for_argocd_sync"
            break
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""
    
    log_info "Waiting complete"
}

# Step 10: Print status and access instructions
print_status() {
    log_step_start "print_status"
    # Use the user kubeconfig (same logic as configure_kubeconfig)
    local target_user="${SUDO_USER:-ubuntu}"
    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -n "$target_home" && -f "${target_home}/.kube/config" ]]; then
        export KUBECONFIG="${target_home}/.kube/config"
    else
        # Fallback to root kubeconfig if user config doesn't exist
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi
    
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}Infrastructure Bootstrap Complete!${NC}"
    echo "================================================================================"
    echo ""
    echo -e "Environment: ${YELLOW}${K8S_ENV}${NC}"
    echo ""
    
    log_info "ArgoCD Application Status:"
    k3s kubectl get application "platform-${K8S_ENV}" -n argocd 2>/dev/null || log_warn "ArgoCD Application not found"
    
    echo ""
    log_info "ArgoCD Pods:"
    k3s kubectl get pods -n argocd
    
    echo ""
    log_info "Application Pods (deployed by ArgoCD):"
    k3s kubectl get pods
    
    echo ""
    log_info "Service Status:"
    k3s kubectl get svc
    
    echo ""
    log_info "Access Instructions:"
    echo "  - Get your EC2 public IP: curl -s http://169.254.169.254/latest/meta-data/public-ipv4"
    echo "  - Or check AWS Console for your instance's public IP"
    echo ""
    
    # Try to get public IP
    PUBLIC_IP=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
    
    if [[ -n "$PUBLIC_IP" ]]; then
        echo -e "  ${GREEN}Access your application at:${NC}"
        echo -e "    ${YELLOW}http://${PUBLIC_IP}/${NC}"
        echo ""
        echo -e "  ${GREEN}Access ArgoCD UI at:${NC}"
        echo -e "    ${YELLOW}http://${PUBLIC_IP}:3333${NC}"
        echo -e "    Username: ${YELLOW}admin${NC}"
        echo -e "    Password: ${YELLOW}(custom password set via ARGOCD_ADMIN_PASSWORD)${NC}"
        echo ""
    else
        echo "  Replace <EC2_PUBLIC_IP> with your instance's public IP:"
        echo "    Application: http://<EC2_PUBLIC_IP>/"
        echo "    ArgoCD UI: http://<EC2_PUBLIC_IP>:3333"
        echo ""
    fi
    
    echo "  Verify deployment:"
    echo "    kubectl get pods,svc"
    echo "    kubectl get application -n argocd"
    echo "    kubectl logs -l app=caddy"
    echo ""
    echo "  Troubleshooting:"
    echo "    kubectl describe pod <pod-name>"
    echo "    kubectl logs <pod-name>"
    echo "    kubectl describe application platform-${K8S_ENV} -n argocd"
    echo ""
    echo ""
    log_info "Log File Information:"
    echo "  Log file location: ${LOG_FILE}"
    echo "  Latest log symlink: ${LOG_FILE_LATEST}"
    echo ""
    echo "  To view logs via SSH:"
    echo "    sudo tail -f ${LOG_FILE_LATEST}"
    echo "    sudo cat ${LOG_FILE_LATEST}"
    echo "    sudo less ${LOG_FILE_LATEST}"
    echo ""
    echo "================================================================================"
    log_step_end "print_status"
}

# Main execution
main() {
    # Initialize log directory and file FIRST, before any logging
    init_log_file
    
    log_info "Starting EC2 k3s bootstrap process..."
    log_info "Kubernetes environment: ${K8S_ENV}"
    echo ""
    
    check_root
    check_ubuntu
    
    install_prerequisites
    set_es_kernel_param
    install_k3s
    configure_kubeconfig
    persist_kubeconfig_env
    clone_repo
    set_argocd_password
    install_argocd
    expose_argocd_ui
    apply_argocd_application
    wait_for_argocd_sync
    print_status
    
    log_info "Bootstrap complete!"
    log_to_file "INFO" "Bootstrap script completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================================" >> "$LOG_FILE" 2>/dev/null || true
}

# Run main function
main "$@"

