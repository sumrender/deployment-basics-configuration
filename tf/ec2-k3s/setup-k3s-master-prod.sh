#!/bin/bash
set -euo pipefail

################################################################################
# k3s Master Node Setup Script for Production
# 
# This script sets up a k3s master node, stores the server token in AWS
# Parameter Store, installs ArgoCD, and configures it to deploy applications.
#
# Environment Variables:
#   - K8S_ENV: Kubernetes environment name (default: prod)
#   - REPO_URL: GitHub repository URL to clone
#   - REPO_BRANCH: GitHub repository branch to clone
#   - ARGOCD_ADMIN_PASSWORD: ArgoCD admin password (required)
#   - K3S_TOKEN_PARAMETER_NAME: Parameter Store name for k3s server token
#   - K3S_MASTER_IP_PARAMETER_NAME: Parameter Store name for master IP
#   - AWS_REGION: AWS region for Parameter Store
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="${REPO_URL:-https://github.com/sumrender/deployment-basics-configuration.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/tmp/deployment-basics-configuration}"
K8S_ENV="${K8S_ENV:-prod}"
K3S_TOKEN_PARAMETER_NAME="${K3S_TOKEN_PARAMETER_NAME:-/k3s/prod/server-token}"
K3S_MASTER_IP_PARAMETER_NAME="${K3S_MASTER_IP_PARAMETER_NAME:-/k3s/prod/master-ip}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# Source common installation functions
COMMON_SCRIPT="/tmp/install-k3s-common.sh"
if [[ ! -f "$COMMON_SCRIPT" ]]; then
    # Download common script from GitHub if not present
    REPO_PATH="${REPO_URL}"
    REPO_PATH="${REPO_PATH#https://github.com/}"
    REPO_PATH="${REPO_PATH#http://github.com/}"
    REPO_PATH="${REPO_PATH#git@github.com:}"
    REPO_PATH="${REPO_PATH%.git}"
    
    RAW_COMMON_URL="https://raw.githubusercontent.com/${REPO_PATH}/${REPO_BRANCH}/tf/ec2-k3s/install-k3s-common.sh"
    curl -fsSL -o "$COMMON_SCRIPT" "$RAW_COMMON_URL"
    chmod +x "$COMMON_SCRIPT"
fi

source "$COMMON_SCRIPT"

# Helper functions
log_info() {
    local message="$1"
    echo -e "${GREEN}[INFO]${NC} $message"
}

log_warn() {
    local message="$1"
    echo -e "${YELLOW}[WARN]${NC} $message"
}

log_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Verify AWS access and credentials
verify_aws_access() {
    log_info "Verifying AWS access and credentials..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed or not in PATH"
        exit 1
    fi
    
    # Check if AWS CLI is configured
    if ! aws --version &> /dev/null; then
        log_error "AWS CLI is not working properly"
        exit 1
    fi
    
    # Verify IAM role credentials are available
    log_info "Checking IAM role credentials..."
    local identity_output
    if ! identity_output=$(aws sts get-caller-identity --region "$AWS_REGION" 2>&1); then
        log_error "Failed to get AWS caller identity"
        log_error "AWS CLI error: $identity_output"
        log_error "This usually means IAM instance profile is not attached or not ready yet"
        exit 1
    fi
    
    log_info "AWS credentials verified:"
    echo "$identity_output" | grep -E "(UserId|Account|Arn)" || echo "$identity_output"
    
    # Test basic SSM access with describe operation
    log_info "Testing SSM access..."
    local ssm_test_output
    if ! ssm_test_output=$(aws ssm describe-parameters --region "$AWS_REGION" --max-items 1 2>&1); then
        log_warn "SSM describe-parameters test failed (this may be expected if no parameters exist)"
        log_warn "Error: $ssm_test_output"
        log_warn "Continuing anyway - this may indicate a permissions issue"
    else
        log_info "SSM access verified"
    fi
}

# Store k3s server token in Parameter Store
store_k3s_token() {
    log_info "Storing k3s server token in Parameter Store..."
    
    local token_file="/var/lib/rancher/k3s/server/node-token"
    if [[ ! -f "$token_file" ]]; then
        log_error "k3s server token file not found at ${token_file}"
        exit 1
    fi
    
    local token
    token=$(cat "$token_file")
    
    # Retry logic for IAM propagation delays
    local max_attempts=3
    local attempt=1
    local delay=5
    local error_output=""
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt of $max_attempts to store k3s server token..."
        
        if error_output=$(aws ssm put-parameter \
            --name "$K3S_TOKEN_PARAMETER_NAME" \
            --value "$token" \
            --type "SecureString" \
            --region "$AWS_REGION" \
            --overwrite 2>&1); then
            log_info "k3s server token stored in Parameter Store: ${K3S_TOKEN_PARAMETER_NAME}"
            
            # Verify parameter was successfully stored
            if aws ssm get-parameter \
                --name "$K3S_TOKEN_PARAMETER_NAME" \
                --region "$AWS_REGION" \
                --with-decryption \
                --query 'Parameter.Value' \
                --output text &> /dev/null; then
                log_info "Verified: Parameter successfully stored and retrievable"
                return 0
            else
                log_warn "Parameter stored but verification failed (this may be expected)"
            fi
            return 0
        else
            log_warn "Attempt $attempt failed: $error_output"
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Retrying in ${delay} seconds..."
                sleep $delay
                delay=$((delay * 2))  # Exponential backoff
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    log_error "Failed to store k3s server token in Parameter Store after $max_attempts attempts"
    log_error "Last AWS CLI error: $error_output"
    log_error "Parameter name: ${K3S_TOKEN_PARAMETER_NAME}"
    log_error "Region: ${AWS_REGION}"
    exit 1
}

# Store master IP in Parameter Store
store_master_ip() {
    log_info "Storing master node IP in Parameter Store..."
    
    local master_ip
    master_ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
    
    if [[ -z "$master_ip" ]]; then
        log_error "Failed to retrieve master node IP"
        exit 1
    fi
    
    # Retry logic for IAM propagation delays
    local max_attempts=3
    local attempt=1
    local delay=5
    local error_output=""
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt of $max_attempts to store master IP..."
        
        if error_output=$(aws ssm put-parameter \
            --name "$K3S_MASTER_IP_PARAMETER_NAME" \
            --value "$master_ip" \
            --type "String" \
            --region "$AWS_REGION" \
            --overwrite 2>&1); then
            log_info "Master node IP stored in Parameter Store: ${K3S_MASTER_IP_PARAMETER_NAME} = ${master_ip}"
            
            # Verify parameter was successfully stored
            local retrieved_ip
            if retrieved_ip=$(aws ssm get-parameter \
                --name "$K3S_MASTER_IP_PARAMETER_NAME" \
                --region "$AWS_REGION" \
                --query 'Parameter.Value' \
                --output text 2>&1); then
                if [[ "$retrieved_ip" == "$master_ip" ]]; then
                    log_info "Verified: Parameter successfully stored and matches"
                else
                    log_warn "Parameter stored but retrieved value doesn't match (expected: $master_ip, got: $retrieved_ip)"
                fi
            else
                log_warn "Parameter stored but verification failed: $retrieved_ip"
            fi
            return 0
        else
            log_warn "Attempt $attempt failed: $error_output"
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "Retrying in ${delay} seconds..."
                sleep $delay
                delay=$((delay * 2))  # Exponential backoff
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    log_error "Failed to store master node IP in Parameter Store after $max_attempts attempts"
    log_error "Last AWS CLI error: $error_output"
    log_error "Parameter name: ${K3S_MASTER_IP_PARAMETER_NAME}"
    log_error "Region: ${AWS_REGION}"
    exit 1
}

# Set ArgoCD admin password
set_argocd_password() {
    local argocd_password="${ARGOCD_ADMIN_PASSWORD:-}"
    
    if [[ -z "$argocd_password" ]]; then
        log_error "ARGOCD_ADMIN_PASSWORD environment variable is required but not set"
        exit 1
    fi
    
    log_info "Setting ArgoCD admin password..."
    
    # Create namespace first
    if ! k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f - > /dev/null 2>&1; then
        log_error "Failed to create argocd namespace"
        exit 1
    fi
    
    # Install apache2-utils for htpasswd (if not already installed)
    if ! command -v htpasswd &> /dev/null; then
        log_info "Installing apache2-utils for password hashing..."
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y -qq apache2-utils > /dev/null; then
            log_error "Failed to install apache2-utils"
            exit 1
        fi
    fi
    
    # Generate bcrypt hash
    # Note: ArgoCD uses $2a$ format, htpasswd generates $2y$, so we convert
    local bcrypt_hash
    if ! bcrypt_hash=$(htpasswd -bnBC 10 "" "$argocd_password" | tr -d ':\n' | sed 's/$2y/$2a/'); then
        log_error "Failed to generate password hash"
        exit 1
    fi
    
    # Create the secret (ArgoCD will use this if it exists)
    if ! k3s kubectl create secret generic argocd-initial-admin-secret \
        --from-literal=password="$bcrypt_hash" \
        -n argocd \
        --dry-run=client -o yaml | k3s kubectl apply -f - > /dev/null 2>&1; then
        log_error "Failed to create ArgoCD password secret"
        exit 1
    fi
    
    log_info "ArgoCD admin password secret created"
}

# Install ArgoCD
install_argocd() {
    log_info "Installing ArgoCD..."
    
    # Create namespace (if not already created)
    if ! k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f - > /dev/null 2>&1; then
        log_error "Failed to create argocd namespace"
        exit 1
    fi
    
    # Install ArgoCD
    if ! k3s kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml > /dev/null 2>&1; then
        log_error "Failed to apply ArgoCD manifests"
        exit 1
    fi
    
    # Wait for ArgoCD server to be ready
    log_info "Waiting for ArgoCD to be ready (this may take 2-3 minutes)..."
    if ! k3s kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s > /dev/null 2>&1; then
        log_error "ArgoCD server failed to start within timeout"
        exit 1
    fi
    
    log_info "ArgoCD installed and ready"
}

# Expose ArgoCD UI on port 30033 via systemd port-forward
expose_argocd_ui() {
    log_info "Exposing ArgoCD UI on port 30033 (port-forward via systemd)..."
    
    local target_user="${SUDO_USER:-ubuntu}"
    
    if ! id "$target_user" &>/dev/null; then
        log_error "User '${target_user}' does not exist"
        exit 1
    fi
    
    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        log_error "Cannot determine home for user '${target_user}'"
        exit 1
    fi
    
    local kubeconfig_path="${target_home}/.kube/config"
    if [[ ! -f "$kubeconfig_path" ]]; then
        log_error "kubeconfig not found at ${kubeconfig_path}"
        exit 1
    fi
    
    # Create systemd service file
    local systemd_service="/etc/systemd/system/argocd-port-forward.service"
    
    cat > "$systemd_service" <<EOF
[Unit]
Description=ArgoCD UI Port Forward
After=network.target

[Service]
Type=simple
User=${target_user}
Restart=always
RestartSec=10
ExecStart=/usr/local/bin/k3s kubectl port-forward svc/argocd-server -n argocd 30033:443 --address=0.0.0.0
Environment="KUBECONFIG=${kubeconfig_path}"

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd daemon
    if ! systemctl daemon-reload; then
        log_error "Failed to reload systemd daemon"
        exit 1
    fi
    
    # Enable and start the service
    if ! systemctl enable argocd-port-forward.service; then
        log_error "Failed to enable argocd-port-forward service"
        exit 1
    fi
    
    if ! systemctl start argocd-port-forward.service; then
        log_error "Failed to start argocd-port-forward service"
        exit 1
    fi
    
    # Wait a moment for service to initialize
    sleep 2
    
    # Verify service is running
    if systemctl is-active --quiet argocd-port-forward.service; then
        log_info "ArgoCD UI exposed on port 30033 via port-forward"
    else
        log_warn "ArgoCD port-forward service may not be running. Check status: systemctl status argocd-port-forward.service"
    fi
}

# Clone repository
clone_repo() {
    log_info "Cloning repository: $REPO_URL (branch: $REPO_BRANCH)"
    
    if [[ -d "$REPO_DIR" ]]; then
        log_warn "Repository directory already exists: $REPO_DIR"
        log_info "Pulling latest changes..."
        cd "$REPO_DIR"
        if ! git fetch origin && \
           (git checkout "$REPO_BRANCH" 2>/dev/null || true) && \
           git pull origin "$REPO_BRANCH"; then
            log_error "Failed to pull latest changes"
            exit 1
        fi
    else
        if ! git clone -b "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"; then
            log_error "Failed to clone repository"
            exit 1
        fi
    fi
    
    log_info "Repository ready at: $REPO_DIR"
}

# Apply ArgoCD Application
apply_argocd_application() {
    log_info "Applying ArgoCD Application for environment: ${K8S_ENV}"
    
    cd "$REPO_DIR"
    
    # Validate K8S_ENV
    local argocd_app_path="argocd/${K8S_ENV}/application.yaml"
    if [[ ! -f "$argocd_app_path" ]]; then
        log_error "ArgoCD Application manifest not found: ${argocd_app_path}"
        exit 1
    fi
    
    # Use the user kubeconfig
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
    if ! k3s kubectl apply -f "$argocd_app_path"; then
        log_error "Failed to apply ArgoCD Application"
        exit 1
    fi
    
    # Wait for Application CRD to be established
    log_info "Waiting for ArgoCD Application CRD to be established..."
    if ! k3s kubectl wait --for=condition=established crd applications.argoproj.io --timeout=60s > /dev/null 2>&1; then
        log_warn "Application CRD not established within timeout, continuing anyway..."
    fi
    
    log_info "ArgoCD Application applied"
}

# Wait for ArgoCD sync
wait_for_argocd_sync() {
    log_info "Waiting for ArgoCD Application 'platform-${K8S_ENV}' to sync..."
    
    # Use the user kubeconfig
    local target_user="${SUDO_USER:-ubuntu}"
    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -n "$target_home" && -f "${target_home}/.kube/config" ]]; then
        export KUBECONFIG="${target_home}/.kube/config"
    else
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi
    
    local app_name="platform-${K8S_ENV}"
    local timeout=600  # 10 minutes
    local elapsed=0
    
    while true; do
        local status
        status=$(k3s kubectl get application "$app_name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$status" == "Synced" ]]; then
            log_info "ArgoCD Application synced successfully!"
            break
        fi
        
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "ArgoCD sync timeout (${timeout}s). Current status: ${status}"
            log_warn "Check status manually: kubectl get application -n argocd"
            break
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""
    
    log_info "Waiting complete"
}

# Main execution
main() {
    log_info "Starting k3s master node setup for production..."
    log_info "Kubernetes environment: ${K8S_ENV}"
    echo ""
    
    check_root
    
    # Verify AWS access before proceeding
    verify_aws_access
    
    # Install prerequisites
    install_k3s_prerequisites
    set_es_kernel_param
    
    # Install k3s as server
    install_k3s_binary "server" "--disable traefik"
    wait_for_k3s_ready
    
    # Store token and IP in Parameter Store
    store_k3s_token
    store_master_ip
    
    # Configure kubeconfig
    configure_kubeconfig
    persist_kubeconfig_env
    
    # Clone repository
    clone_repo
    
    # Set ArgoCD password (before installing ArgoCD)
    set_argocd_password
    
    # Install ArgoCD
    install_argocd
    
    # Expose ArgoCD UI
    expose_argocd_ui
    
    # Apply ArgoCD Application
    apply_argocd_application
    
    # Wait for sync
    wait_for_argocd_sync
    
    log_info "Master node setup complete!"
    echo ""
    log_info "Master node IP: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
    log_info "Access ArgoCD UI at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):30033"
}

# Run main function
main "$@"

