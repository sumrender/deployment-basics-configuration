#!/bin/bash
set -euo pipefail

################################################################################
# k3s Master Node Setup Script for Production
# 
# This script sets up a k3s master node, installs ArgoCD, and configures it
# to deploy applications.
#
# Environment Variables:
#   - K8S_ENV: Kubernetes environment name (default: prod)
#   - REPO_URL: GitHub repository URL to clone
#   - REPO_BRANCH: GitHub repository branch to clone
#   - ARGOCD_ADMIN_PASSWORD: ArgoCD admin password (required)
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

# Source common installation functions
COMMON_SCRIPT="/tmp/install-k3s-common.sh"
if [[ ! -f "$COMMON_SCRIPT" ]]; then
    # Download common script from GitHub if not present
    REPO_PATH="${REPO_URL}"
    REPO_PATH="${REPO_PATH#https://github.com/}"
    REPO_PATH="${REPO_PATH#http://github.com/}"
    REPO_PATH="${REPO_PATH#git@github.com:}"
    REPO_PATH="${REPO_PATH%.git}"
    
    RAW_COMMON_URL="https://raw.githubusercontent.com/${REPO_PATH}/${REPO_BRANCH}/tf/ec2-k3s/prod/scripts/install-k3s-common.sh"
    curl -fsSL -o "$COMMON_SCRIPT" "$RAW_COMMON_URL"
    chmod +x "$COMMON_SCRIPT"
fi

source "$COMMON_SCRIPT"

# Helper functions
log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[INFO]${NC} [${timestamp}] $message"
}

log_warn() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARN]${NC} [${timestamp}] $message"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} [${timestamp}] $message"
}

# Fetch IMDSv2 token
get_imds_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

# Get AWS provider ID for k3s node
# Returns provider ID in format: aws:///<availability-zone>/<instance-id>
# Requires IMDS_TOKEN to be set in the calling scope
# Note: Log messages are redirected to stderr to avoid polluting stdout
get_provider_id() {
    log_info "Retrieving instance metadata for AWS provider ID..." >&2
    
    local instance_id
    instance_id=$(curl -s \
        -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id)
    
    local availability_zone
    availability_zone=$(curl -s \
        -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone)
    
    if [[ -z "$instance_id" ]] || [[ -z "$availability_zone" ]]; then
        log_error "Failed to retrieve instance ID or availability zone from EC2 metadata" >&2
        exit 1
    fi
    
    local provider_id="aws:///${availability_zone}/${instance_id}"
    log_info "AWS provider ID: ${provider_id}" >&2
    echo "$provider_id"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
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

# Write k3s token and master IP to SSM Parameter Store
write_to_ssm() {
    log_info "Writing k3s token and master IP to SSM Parameter Store..."
    
    # Ensure AWS_BIN is set
    : "${AWS_BIN:?AWS_BIN is not set – AWS CLI not initialized}"
    
    # Get AWS region from instance metadata
    local aws_region
    if ! aws_region=$(curl -s --connect-timeout 2 \
        -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null); then
        log_error "Failed to retrieve AWS region from instance metadata"
        exit 1
    fi
    
    log_info "AWS region: ${aws_region}"
    
    # Verify AWS CLI binary is available
    if ! [[ -x "$AWS_BIN" ]]; then
        log_error "AWS CLI binary not found or not executable: $AWS_BIN"
        exit 1
    fi
    
    # Verify IAM role credentials are available
    if ! "$AWS_BIN" sts get-caller-identity --region "${aws_region}" > /dev/null 2>&1; then
        log_error "AWS credentials not available. Check IAM instance profile."
        exit 1
    fi
    
    local caller_identity
    caller_identity=$("$AWS_BIN" sts get-caller-identity --region "${aws_region}" --output json 2>/dev/null)
    log_info "AWS credentials verified: $(echo "$caller_identity" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)"
    
    # Get master private IP from instance metadata
    local master_ip
    if ! master_ip=$(curl -s --connect-timeout 2 \
        -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null); then
        log_error "Failed to retrieve master private IP from instance metadata"
        exit 1
    fi
    
    log_info "Master private IP: ${master_ip}"
    
    # Read k3s token from master node
    local k3s_token
    local token_file="/var/lib/rancher/k3s/server/node-token"
    
    if [ ! -f "$token_file" ]; then
        log_error "k3s token file not found: ${token_file}"
        exit 1
    fi
    
    if ! k3s_token=$(sudo cat "$token_file" 2>/dev/null); then
        log_error "Failed to read k3s token from ${token_file}"
        exit 1
    fi
    
    # Trim whitespace from token
    k3s_token=$(echo "$k3s_token" | tr -d '\r\n' | xargs)
    
    if [ -z "$k3s_token" ]; then
        log_error "k3s token is empty after reading"
        exit 1
    fi
    
    local token_length=${#k3s_token}
    log_info "k3s token retrieved (length: ${token_length} characters)"
    log_info "Token preview: ${k3s_token:0:20}...${k3s_token: -10} (masked)"
    
    # SSM parameter names
    local token_param="/k3s/prod/token"
    local master_ip_param="/k3s/prod/master-ip"
    
    # Write master IP to SSM
    log_info "Writing master IP to SSM parameter: ${master_ip_param}"
    if ! "$AWS_BIN" ssm put-parameter \
        --region "${aws_region}" \
        --name "${master_ip_param}" \
        --value "${master_ip}" \
        --type "String" \
        --overwrite \
        --description "k3s master node private IP address" \
        > /dev/null 2>&1; then
        log_error "Failed to write master IP to SSM parameter: ${master_ip_param}"
        exit 1
    fi
    
    log_info "✓ Master IP successfully written to SSM: ${master_ip_param}=${master_ip}"
    
    # Write token to SSM (SecureString)
    log_info "Writing k3s token to SSM parameter: ${token_param}"
    if ! "$AWS_BIN" ssm put-parameter \
        --region "${aws_region}" \
        --name "${token_param}" \
        --value "${k3s_token}" \
        --type "SecureString" \
        --overwrite \
        --description "k3s master node token for worker node registration" \
        > /dev/null 2>&1; then
        log_error "Failed to write k3s token to SSM parameter: ${token_param}"
        exit 1
    fi
    
    log_info "✓ k3s token successfully written to SSM: ${token_param} (SecureString, encrypted)"
    
    # Verify parameters were written correctly
    log_info "Verifying SSM parameters..."
    local verify_ip
    verify_ip=$("$AWS_BIN" ssm get-parameter \
        --region "${aws_region}" \
        --name "${master_ip_param}" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo "")
    
    local verify_token_length
    verify_token_length=$("$AWS_BIN" ssm get-parameter \
        --region "${aws_region}" \
        --name "${token_param}" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null | wc -c || echo "0")
    
    if [ "$verify_ip" = "$master_ip" ] && [ "$verify_token_length" -gt 0 ]; then
        log_info "✓ SSM parameter verification successful"
        log_info "  - ${master_ip_param}: ${verify_ip}"
        log_info "  - ${token_param}: retrieved (length: $((verify_token_length - 1)) characters)"
    else
        log_warn "SSM parameter verification failed or incomplete"
        log_warn "  - Expected IP: ${master_ip}, Got: ${verify_ip}"
        log_warn "  - Token length: ${verify_token_length}"
    fi
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
    
    # Acquire IMDSv2 token at script start
    IMDS_TOKEN="$(get_imds_token)"
    
    if [[ -z "$IMDS_TOKEN" ]]; then
        log_error "Failed to acquire IMDSv2 token"
        exit 1
    fi
    
    check_root
    
    # Install prerequisites
    install_k3s_prerequisites
    set_es_kernel_param
    
    # Get private IP before installing k3s (needed for network configuration)
    log_info "Retrieving master node private IP..."
    local master_ip
    master_ip=$(curl -s \
        -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/local-ipv4)
    
    if [[ -z "$master_ip" ]]; then
        log_error "Failed to retrieve master node private IP"
        exit 1
    fi
    
    log_info "Master node private IP: ${master_ip}"
    
    # Get AWS provider ID for k3s node
    local provider_id
    provider_id=$(get_provider_id)
    
    log_info "Configuring k3s to bind to all interfaces and include private IP in TLS certificate..."
    
    # Install k3s as server with network configuration and AWS provider ID
    # --bind-address: IP address to bind to (0.0.0.0 listens on all interfaces)
    # --advertise-address: IP address to advertise to other nodes
    # --tls-san: Add IP to TLS certificate Subject Alternative Names
    # --kubelet-arg=provider-id: Set AWS provider ID for cluster autoscaler compatibility
    # Note: --disable traefik is already included in install_k3s_binary function
    install_k3s_binary "server" "--bind-address 0.0.0.0 --advertise-address ${master_ip} --tls-san ${master_ip} --kubelet-arg=provider-id=${provider_id}"
    wait_for_k3s_ready
    verify_traefik_disabled

    # Write token and IP to SSM Parameter Store
    write_to_ssm
    
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
    log_info "Master node IP: $(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)"
    log_info "Access ArgoCD UI at: http://$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4):30033"
}

# Run main function
main "$@"

