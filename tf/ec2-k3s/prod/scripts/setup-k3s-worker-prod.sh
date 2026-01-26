#!/bin/bash
set -euo pipefail

################################################################################
# k3s Worker Node Setup Script for Production
# 
# This script sets up a k3s worker node that joins an existing k3s cluster
# by retrieving the server token and master IP from AWS SSM Parameter Store.
#
# SSM Parameters:
#   - /k3s/prod/token: k3s server token (SecureString)
#   - /k3s/prod/master-ip: Master node IP address (String)
#
# The script will retry retrieving these parameters with exponential backoff
# to handle cases where the master node is still setting up.
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - values come from environment variables

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
# Acquires a fresh IMDSv2 token internally
get_provider_id() {
    log_info "Retrieving instance metadata for AWS provider ID..."
    
    local imds_token
    imds_token=$(get_imds_token)
    
    if [[ -z "$imds_token" ]]; then
        log_error "Failed to acquire IMDSv2 token"
        exit 1
    fi
    
    local instance_id
    instance_id=$(curl -s \
        -H "X-aws-ec2-metadata-token: $imds_token" \
        http://169.254.169.254/latest/meta-data/instance-id)
    
    local availability_zone
    availability_zone=$(curl -s \
        -H "X-aws-ec2-metadata-token: $imds_token" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone)
    
    if [[ -z "$instance_id" ]] || [[ -z "$availability_zone" ]]; then
        log_error "Failed to retrieve instance ID or availability zone from EC2 metadata"
        exit 1
    fi
    
    local provider_id="aws:///${availability_zone}/${instance_id}"
    log_info "AWS provider ID: ${provider_id}"
    echo "$provider_id"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}


# Wait for node to join cluster
# Usage: wait_for_node_ready <master_ip>
wait_for_node_ready() {
    local master_ip="${1:-}"
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
            if [[ -n "$master_ip" ]]; then
                log_error "  3. Check network connectivity: ping ${master_ip}"
            fi
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
    
    # Get AWS provider ID for k3s node
    local provider_id
    provider_id=$(get_provider_id)
    
    # Set environment variables for k3s agent installation
    export K3S_URL="https://${master_ip}:6443"
    export K3S_TOKEN="$k3s_token"
    export INSTALL_K3S_EXEC="--kubelet-arg=provider-id=${provider_id}"
    
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

# Retrieve k3s token and master IP from SSM Parameter Store
retrieve_from_ssm() {
    log_info "Retrieving k3s token and master IP from SSM Parameter Store..."
    
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
    
    # SSM parameter names
    local token_param="/k3s/prod/token"
    local master_ip_param="/k3s/prod/master-ip"
    
    # Retrieve parameters with retry logic
    local max_retries=30
    local retry_count=0
    local retry_delay=10
    local k3s_token=""
    local master_ip=""
    
    log_info "Attempting to retrieve SSM parameters (max retries: ${max_retries})..."
    
    while [[ $retry_count -lt $max_retries ]]; do
        retry_count=$((retry_count + 1))
        
        if [[ $retry_count -gt 1 ]]; then
            log_info "Retry attempt ${retry_count}/${max_retries} (waiting ${retry_delay}s before retry)..."
            sleep $retry_delay
            retry_delay=$((retry_delay + 5))  # Exponential backoff with increment
        fi
        
        # Retrieve master IP
        log_info "Retrieving master IP from SSM: ${master_ip_param} (attempt ${retry_count})"
        master_ip=$("$AWS_BIN" ssm get-parameter \
            --region "${aws_region}" \
            --name "${master_ip_param}" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null || echo "")
        
        # Retrieve token
        log_info "Retrieving k3s token from SSM: ${token_param} (attempt ${retry_count})"
        k3s_token=$("$AWS_BIN" ssm get-parameter \
            --region "${aws_region}" \
            --name "${token_param}" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text 2>/dev/null || echo "")
        
        # Validate retrieved values
        if [[ -n "$master_ip" ]] && [[ "$master_ip" != "placeholder-will-be-updated-by-master-node" ]] && \
           [[ -n "$k3s_token" ]] && [[ "$k3s_token" != "placeholder-will-be-updated-by-master-node" ]]; then
            # Validate IP format (basic check)
            if ! echo "$master_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                log_warn "Master IP format may be invalid: ${master_ip}, but continuing..."
            fi
            
            # Validate token is not empty
            local token_trimmed=$(echo "$k3s_token" | tr -d '[:space:]')
            if [[ -z "$token_trimmed" ]]; then
                log_warn "Token appears to be empty, will retry..."
                continue
            fi
            
            log_info "✓ Successfully retrieved SSM parameters:"
            log_info "  - ${master_ip_param}: ${master_ip}"
            log_info "  - ${token_param}: retrieved (length: ${#k3s_token} characters, masked)"
            log_info "  Token preview: ${k3s_token:0:20}...${k3s_token: -10} (masked)"
            
            # Export as environment variables for use in this script
            export K3S_TOKEN="$k3s_token"
            export K3S_MASTER_IP="$master_ip"
            
            return 0
        else
            log_warn "SSM parameters not ready yet or contain placeholder values"
            if [[ -z "$master_ip" ]]; then
                log_warn "  - Master IP: not retrieved"
            elif [[ "$master_ip" == "placeholder-will-be-updated-by-master-node" ]]; then
                log_warn "  - Master IP: still contains placeholder value"
            else
                log_info "  - Master IP: ${master_ip}"
            fi
            
            if [[ -z "$k3s_token" ]]; then
                log_warn "  - Token: not retrieved"
            elif [[ "$k3s_token" == "placeholder-will-be-updated-by-master-node" ]]; then
                log_warn "  - Token: still contains placeholder value"
            else
                log_info "  - Token: retrieved (length: ${#k3s_token})"
            fi
        fi
    done
    
    log_error "Failed to retrieve SSM parameters after ${max_retries} attempts"
    log_error "This usually means:"
    log_error "  1. Master node has not completed setup yet"
    log_error "  2. Master node failed to write parameters to SSM"
    log_error "  3. IAM permissions are insufficient"
    log_error "  4. SSM parameter names are incorrect"
    log_error ""
    log_error "Troubleshooting steps:"
    log_error "  1. Check master node logs: sudo tail -n 200 /var/log/cloud-init-output.log"
    log_error "  2. Verify SSM parameters exist: $AWS_BIN ssm get-parameter --name ${token_param} --region ${aws_region}"
    log_error "  3. Check IAM instance profile permissions"
    exit 1
}

# Main execution
main() {
    log_info "Starting k3s worker node setup for production..."
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
    
    # Retrieve token and master IP from SSM
    retrieve_from_ssm
    
    local k3s_token="$K3S_TOKEN"
    local master_ip="$K3S_MASTER_IP"
    
    log_info "k3s server token retrieved from SSM (length: ${#k3s_token} characters)"
    log_info "Master node IP retrieved from SSM: ${master_ip}"
    
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
    wait_for_node_ready "$master_ip"
    
    log_info "Worker node setup complete!"
    log_info "This node should appear in the cluster shortly."
    log_info "Check on master node with: kubectl get nodes"
}

# Run main function
main "$@"

