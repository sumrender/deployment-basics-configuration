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
    log_error "Troubleshooting steps:"
    log_error "  1. Verify the master node has completed setup"
    log_error "  2. Check AWS Parameter Store: ${K3S_TOKEN_PARAMETER_NAME}"
    log_error "  3. Verify IAM permissions for Parameter Store access"
    log_error "  4. Check AWS region: ${AWS_REGION}"
    log_error "  5. Review master node logs to ensure token was stored"
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
    log_error "Troubleshooting steps:"
    log_error "  1. Verify the master node has completed setup"
    log_error "  2. Check AWS Parameter Store: ${K3S_MASTER_IP_PARAMETER_NAME}"
    log_error "  3. Verify IAM permissions for Parameter Store access"
    log_error "  4. Check AWS region: ${AWS_REGION}"
    log_error "  5. Review master node logs to ensure IP was stored"
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
            log_error "The agent service installation completed but the service is not running."
            # Inspect failure before exiting
            inspect_k3s_agent_failure
            log_error ""
            log_error "Additional troubleshooting:"
            log_error "  1. Check master node is running: kubectl get nodes (on master)"
            log_error "  2. Verify security groups allow traffic on port 6443"
            log_error "  3. Check network connectivity: ping ${master_ip}"
            log_error "  4. Review full logs: journalctl -xeu k3s-agent.service"
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

# Install k3s agent with retry logic and error handling
install_k3s_agent_with_retry() {
    local master_ip="$1"
    local k3s_token="$2"
    local max_retries=3
    local retry_count=0
    local retry_delay=10
    
    # Set environment variables for k3s agent installation
    export K3S_URL="https://${master_ip}:6443"
    export K3S_TOKEN="$k3s_token"
    
    log_info "Installing k3s as agent to join master at ${master_ip}..."
    log_info "K3S_URL: ${K3S_URL}"
    
    while [[ $retry_count -lt $max_retries ]]; do
        retry_count=$((retry_count + 1))
        
        if [[ $retry_count -gt 1 ]]; then
            log_warn "Retrying k3s agent installation (attempt $retry_count/$max_retries)..."
            log_info "Waiting ${retry_delay} seconds before retry..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        fi
        
        # Verify master is ready before attempting installation
        if ! check_master_api_readiness "$master_ip" 60 12; then
            if [[ $retry_count -lt $max_retries ]]; then
                log_warn "Master not ready, will retry in ${retry_delay} seconds..."
                continue
            else
                log_error "Master API server not ready after multiple attempts"
                log_error "Cannot proceed with agent installation"
                log_error ""
                log_error "Troubleshooting steps:"
                log_error "  1. Verify master node is running and k3s server is installed"
                log_error "  2. Check master node logs for k3s server startup issues"
                log_error "  3. Verify security group allows inbound traffic on port 6443 from workers"
                log_error "  4. Test connectivity manually: curl -k https://${master_ip}:6443"
                log_error "  5. Check master node: systemctl status k3s"
                exit 1
            fi
        fi
        
        # Attempt installation
        log_info "Attempting k3s agent installation (attempt $retry_count/$max_retries)..."
        
        # Temporarily disable exit on error to capture installation failure
        set +e
        install_k3s_binary "agent"
        local install_result=$?
        set -e
        
        if [[ $install_result -eq 0 ]]; then
            # Installation succeeded, but check if service started
            log_info "k3s agent installation completed"
            
            # Wait a moment for service to initialize
            sleep 3
            
            # Check if service is running
            if systemctl is-active --quiet k3s-agent 2>/dev/null; then
                log_info "k3s agent service is running successfully"
                return 0
            else
                log_warn "k3s agent installed but service is not running"
                # Show diagnostics
                inspect_k3s_agent_failure
                
                if [[ $retry_count -lt $max_retries ]]; then
                    log_warn "Will retry installation..."
                    # Try to clean up failed installation
                    if [[ -f /usr/local/bin/k3s-agent-uninstall.sh ]]; then
                        log_info "Cleaning up failed installation..."
                        /usr/local/bin/k3s-agent-uninstall.sh > /dev/null 2>&1 || true
                    fi
                    continue
                else
                    log_error "k3s agent service failed to start after ${max_retries} attempts"
                    exit 1
                fi
            fi
        else
            log_error "k3s agent installation failed (attempt $retry_count/$max_retries)"
            
            if [[ $retry_count -lt $max_retries ]]; then
                log_warn "Will retry installation..."
                # Clean up any partial installation
                if [[ -f /usr/local/bin/k3s-agent-uninstall.sh ]]; then
                    log_info "Cleaning up failed installation..."
                    /usr/local/bin/k3s-agent-uninstall.sh > /dev/null 2>&1 || true
                fi
                continue
            else
                log_error "k3s agent installation failed after ${max_retries} attempts"
                inspect_k3s_agent_failure
                exit 1
            fi
        fi
    done
    
    log_error "Failed to install k3s agent after ${max_retries} attempts"
    inspect_k3s_agent_failure
    exit 1
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
    
    # Verify master is ready before attempting installation
    log_info "Verifying master node readiness before agent installation..."
    log_info "This may take a few minutes if the master node is still starting up..."
    if ! check_master_api_readiness "$master_ip" 300 30; then
        log_error "Master node is not ready. Cannot proceed with worker node setup."
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Wait for master node to complete setup (check master node logs)"
        log_error "  2. Verify master node is running: systemctl status k3s (on master)"
        log_error "  3. Check security groups allow traffic on port 6443 from worker to master"
        log_error "  4. Test connectivity: curl -k https://${master_ip}:6443"
        log_error "  5. Verify master IP is correct: ${master_ip}"
        exit 1
    fi
    
    # Install k3s as agent with retry logic
    install_k3s_agent_with_retry "$master_ip" "$k3s_token"
    
    # Wait for agent to be ready (check systemd service instead of kubectl)
    wait_for_node_ready
    
    log_info "Worker node setup complete!"
    log_info "This node should appear in the cluster shortly."
    log_info "Check on master node with: kubectl get nodes"
}

# Run main function
main "$@"

