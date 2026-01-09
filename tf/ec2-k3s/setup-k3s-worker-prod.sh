#!/bin/bash
set -euo pipefail

################################################################################
# k3s Worker Node Setup Script for Production
# 
# This script sets up a k3s worker node that joins an existing k3s cluster
# by retrieving the server token and master IP from AWS Parameter Store.
#
# Environment Variables:
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
K3S_TOKEN_PARAMETER_NAME="${K3S_TOKEN_PARAMETER_NAME:-/k3s/prod/server-token}"
K3S_MASTER_IP_PARAMETER_NAME="${K3S_MASTER_IP_PARAMETER_NAME:-/k3s/prod/master-ip}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# Source common installation functions
COMMON_SCRIPT="/tmp/install-k3s-common.sh"
if [[ ! -f "$COMMON_SCRIPT" ]]; then
    # Download common script from GitHub if not present
    # We need to get the repo URL from instance metadata or use a default
    REPO_URL="${REPO_URL:-https://github.com/sumrender/deployment-basics-configuration.git}"
    REPO_BRANCH="${REPO_BRANCH:-main}"
    
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

# Retrieve k3s server token from Parameter Store
get_k3s_token() {
    log_info "Retrieving k3s server token from Parameter Store..."
    
    local token
    local max_retries=30
    local retry_count=0
    
    # Wait for master to store the token (with retries)
    while [[ $retry_count -lt $max_retries ]]; do
        if token=$(aws ssm get-parameter \
            --name "$K3S_TOKEN_PARAMETER_NAME" \
            --with-decryption \
            --region "$AWS_REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null); then
            if [[ -n "$token" && "$token" != "None" ]]; then
                log_info "k3s server token retrieved from Parameter Store"
                echo "$token"
                return 0
            fi
        fi
        
        retry_count=$((retry_count + 1))
        log_info "Waiting for master node to store token... (attempt $retry_count/$max_retries)"
        sleep 10
    done
    
    log_error "Failed to retrieve k3s server token from Parameter Store after ${max_retries} attempts"
    log_error "Make sure the master node has completed setup and stored the token"
    exit 1
}

# Retrieve master IP from Parameter Store
get_master_ip() {
    log_info "Retrieving master node IP from Parameter Store..."
    
    local master_ip
    local max_retries=30
    local retry_count=0
    
    # Wait for master to store the IP (with retries)
    while [[ $retry_count -lt $max_retries ]]; do
        if master_ip=$(aws ssm get-parameter \
            --name "$K3S_MASTER_IP_PARAMETER_NAME" \
            --region "$AWS_REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null); then
            if [[ -n "$master_ip" && "$master_ip" != "None" ]]; then
                log_info "Master node IP retrieved from Parameter Store: ${master_ip}"
                echo "$master_ip"
                return 0
            fi
        fi
        
        retry_count=$((retry_count + 1))
        log_info "Waiting for master node to store IP... (attempt $retry_count/$max_retries)"
        sleep 10
    done
    
    log_error "Failed to retrieve master node IP from Parameter Store after ${max_retries} attempts"
    log_error "Make sure the master node has completed setup and stored the IP"
    exit 1
}

# Wait for node to join cluster
wait_for_node_ready() {
    log_info "Waiting for node to join cluster..."
    
    local timeout=120
    local elapsed=0
    
    # Check if k3s agent is running
    while ! systemctl is-active --quiet k3s-agent 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "k3s agent failed to start within ${timeout}s"
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log_info "k3s agent is running"
    
    # Note: We can't check kubectl from worker node directly
    # The master node will see this node once it joins
    log_info "Node should be joining the cluster. Master node will see it shortly."
}

# Main execution
main() {
    log_info "Starting k3s worker node setup for production..."
    echo ""
    
    check_root
    
    # Install prerequisites
    install_k3s_prerequisites
    set_es_kernel_param
    
    # Retrieve token and master IP from Parameter Store
    local k3s_token
    k3s_token=$(get_k3s_token)
    
    local master_ip
    master_ip=$(get_master_ip)
    
    # Install k3s as agent
    log_info "Installing k3s as agent to join master at ${master_ip}..."
    
    # Set environment variables for k3s agent installation
    export K3S_URL="https://${master_ip}:6443"
    export K3S_TOKEN="$k3s_token"
    
    # Install k3s agent (K3S_URL and K3S_TOKEN are already exported)
    install_k3s_binary "agent"
    
    # Wait for agent to be ready (check systemd service instead of kubectl)
    wait_for_node_ready
    
    log_info "Worker node setup complete!"
    log_info "This node should appear in the cluster shortly."
    log_info "Check on master node with: kubectl get nodes"
}

# Run main function
main "$@"

