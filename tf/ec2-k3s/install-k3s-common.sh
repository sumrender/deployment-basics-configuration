#!/bin/bash
# Common k3s installation functions
# This script provides shared functions for installing and configuring k3s
# It should be sourced by master and worker setup scripts

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default k3s install script URL
K3S_INSTALL_SCRIPT="${K3S_INSTALL_SCRIPT:-https://get.k3s.io}"

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

# Install prerequisites (curl, git, kernel parameters)
install_k3s_prerequisites() {
    log_info "Installing prerequisites (curl, git)..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq && apt-get install -y -qq curl git > /dev/null; then
        log_error "Failed to install prerequisites"
        exit 1
    fi
    log_info "Prerequisites installed"
}

# Set Elasticsearch kernel parameter
set_es_kernel_param() {
    log_info "Setting vm.max_map_count for Elasticsearch..."
    if sysctl -w vm.max_map_count=262144 > /dev/null; then
        # Make it persistent across reboots
        if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf
            log_info "Added vm.max_map_count to /etc/sysctl.conf"
        else
            log_info "vm.max_map_count already in /etc/sysctl.conf"
        fi
    else
        log_error "Failed to set vm.max_map_count"
        exit 1
    fi
}

# Install k3s binary (server or agent)
# Usage: install_k3s_binary "server" or "agent" [additional_flags]
# For agents, K3S_URL and K3S_TOKEN should be set as environment variables before calling
install_k3s_binary() {
    local k3s_mode="${1:-server}"
    local additional_flags="${2:-}"
    
    if command -v k3s &> /dev/null; then
        log_warn "k3s appears to be already installed. Skipping installation."
        log_info "To reinstall, uninstall k3s first: /usr/local/bin/k3s-uninstall.sh"
        return
    fi
    
    log_info "Installing k3s as ${k3s_mode}..."
    
    if [[ "$k3s_mode" == "server" ]]; then
        # Construct the k3s exec flags
        local k3s_exec_flags="--disable traefik"
        if [[ -n "$additional_flags" ]]; then
            k3s_exec_flags="${k3s_exec_flags} ${additional_flags}"
        fi
        
        log_info "Installing k3s with flags: ${k3s_exec_flags}"
        log_info "Executing: curl -sfL ${K3S_INSTALL_SCRIPT} | INSTALL_K3S_EXEC='${k3s_exec_flags}' sh -"
        
        # Export INSTALL_K3S_EXEC and run the install script
        if INSTALL_K3S_EXEC="${k3s_exec_flags}" curl -sfL "${K3S_INSTALL_SCRIPT}" | sh -; then
            log_info "k3s installation command completed successfully"
        else
            log_error "k3s installation command failed"
            exit 1
        fi
    else
        # For agent mode, K3S_URL and K3S_TOKEN should be set as env vars
        # The k3s install script will automatically detect agent mode from K3S_URL
        local install_cmd="curl -sfL ${K3S_INSTALL_SCRIPT} | sh -"
        log_info "Executing: ${install_cmd} (with K3S_URL and K3S_TOKEN from environment)"
        if eval "$install_cmd"; then
            log_info "k3s agent installation command completed"
            # Note: Command success doesn't guarantee service is running
            # Caller should verify service status separately
            return 0
        else
            log_error "k3s agent installation command failed"
            return 1
        fi
    fi
}

# Wait for k3s to be ready
wait_for_k3s_ready() {
    local timeout="${1:-60}"
    log_info "Waiting for k3s to be ready (timeout: ${timeout}s)..."
    
    local elapsed=0
    while ! k3s kubectl get nodes &> /dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "k3s failed to start within ${timeout}s"
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log_info "k3s is ready"
}

# Configure kubeconfig for a non-root user
configure_kubeconfig() {
    local kubeconfig_src="/etc/rancher/k3s/k3s.yaml"
    local target_user="${SUDO_USER:-ubuntu}"

    if [[ ! -f "$kubeconfig_src" ]]; then
        log_warn "kubeconfig not found at ${kubeconfig_src}; skipping kubeconfig setup"
        return
    fi

    if ! id "$target_user" &>/dev/null; then
        log_warn "User '${target_user}' does not exist; skipping kubeconfig setup"
        return
    fi

    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        log_warn "Cannot determine home for user '${target_user}'; skipping kubeconfig setup"
        return
    fi

    log_info "Configuring kubeconfig for user '${target_user}'..."
    if mkdir -p "${target_home}/.kube" && \
       cp -f "$kubeconfig_src" "${target_home}/.kube/config" && \
       chown -R "${target_user}:${target_user}" "${target_home}/.kube" && \
       chmod 700 "${target_home}/.kube" && \
       chmod 600 "${target_home}/.kube/config"; then
        log_info "kubeconfig written to ${target_home}/.kube/config"
    else
        log_error "Failed to configure kubeconfig"
        exit 1
    fi
}

# Persist KUBECONFIG environment variable for the user
persist_kubeconfig_env() {
    local target_user="${SUDO_USER:-ubuntu}"

    if ! id "$target_user" &>/dev/null; then
        log_warn "User '${target_user}' does not exist; skipping KUBECONFIG persistence"
        return
    fi

    local target_home
    target_home="$(eval echo "~${target_user}")"
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        log_warn "Cannot determine home for user '${target_user}'; skipping KUBECONFIG persistence"
        return
    fi

    local kubeconfig_path="${target_home}/.kube/config"
    if [[ ! -f "$kubeconfig_path" ]]; then
        log_warn "kubeconfig not found at ${kubeconfig_path}; skipping KUBECONFIG persistence"
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
    local marker="# KUBECONFIG for k3s (added by install-k3s-common.sh)"
    if grep -q "$marker" "$profile_file" 2>/dev/null; then
        log_info "KUBECONFIG export already exists in ${profile_file}, skipping"
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
}

# Test network connectivity to a host and port
# Usage: test_network_connectivity <host> <port> [timeout_seconds]
# Returns 0 if connection successful, 1 otherwise
test_network_connectivity() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    log_info "Testing network connectivity to ${host}:${port}..."
    
    # Try to connect using timeout and nc (netcat) if available, otherwise use bash's /dev/tcp
    if command -v nc &> /dev/null; then
        if timeout "$timeout" nc -z "$host" "$port" 2>/dev/null; then
            log_info "Network connectivity to ${host}:${port} successful"
            return 0
        fi
    elif command -v timeout &> /dev/null; then
        # Use bash's built-in /dev/tcp with timeout
        if timeout "$timeout" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            log_info "Network connectivity to ${host}:${port} successful"
            return 0
        fi
    else
        # Fallback: try without timeout (may hang)
        if bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            log_info "Network connectivity to ${host}:${port} successful"
            return 0
        fi
    fi
    
    log_warn "Network connectivity to ${host}:${port} failed"
    return 1
}

# Check if master API server is ready and responding
# Usage: check_master_api_readiness <master_ip> [timeout_seconds] [max_retries]
# Returns 0 if master is ready, 1 otherwise
check_master_api_readiness() {
    local master_ip="$1"
    local timeout="${2:-300}"  # 5 minutes default
    local max_retries="${3:-30}"
    local retry_count=0
    local elapsed=0
    
    log_info "Checking master API readiness at https://${master_ip}:6443..."
    
    # First, test basic network connectivity
    if ! test_network_connectivity "$master_ip" 6443 10; then
        log_warn "Basic network connectivity test failed, but will retry..."
    fi
    
    # Try to connect to the API server with proper HTTPS check
    while [[ $retry_count -lt $max_retries && $elapsed -lt $timeout ]]; do
        # Test if we can establish a connection (even if SSL verification fails)
        # We use curl with --insecure to test connectivity without valid cert
        if curl -k -s --connect-timeout 5 "https://${master_ip}:6443" > /dev/null 2>&1 || \
           curl -k -s --connect-timeout 5 "https://${master_ip}:6443/healthz" > /dev/null 2>&1 || \
           curl -k -s --connect-timeout 5 "https://${master_ip}:6443/readyz" > /dev/null 2>&1; then
            log_info "Master API server is ready and responding"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        elapsed=$((elapsed + 5))
        if [[ $retry_count -lt $max_retries ]]; then
            log_info "Master API not ready yet, waiting... (attempt $retry_count/$max_retries, elapsed: ${elapsed}s)"
            sleep 5
        fi
    done
    
    log_error "Master API server not ready after ${elapsed}s (${retry_count} attempts)"
    log_error "Master IP: ${master_ip}"
    log_error "This may indicate:"
    log_error "  - Master node is still starting up"
    log_error "  - Network connectivity issues (check security groups)"
    log_error "  - Master API server is not listening on port 6443"
    return 1
}

# Inspect k3s agent service logs and status on failure
# Usage: inspect_k3s_agent_failure
inspect_k3s_agent_failure() {
    log_error "=========================================="
    log_error "k3s Agent Service Failure Diagnostics"
    log_error "=========================================="
    
    # Check if service exists
    if ! systemctl list-unit-files | grep -q k3s-agent.service; then
        log_error "k3s-agent.service not found in systemd"
        return
    fi
    
    # Show service status
    log_error "Systemd service status:"
    systemctl status k3s-agent.service --no-pager -l || true
    echo ""
    
    # Show recent logs
    log_error "Recent k3s-agent service logs (last 50 lines):"
    journalctl -u k3s-agent.service -n 50 --no-pager || true
    echo ""
    
    # Check for common error patterns
    log_error "Checking for common issues..."
    
    # Check if port 6443 is accessible
    if [[ -n "${K3S_URL:-}" ]]; then
        local master_url="${K3S_URL#https://}"
        local master_host="${master_url%%:*}"
        log_error "Testing connectivity to master: ${master_host}:6443"
        if test_network_connectivity "$master_host" 6443 5; then
            log_info "Network connectivity to master is OK"
        else
            log_error "Network connectivity to master FAILED"
            log_error "Check security groups and firewall rules"
        fi
    fi
    
    # Check if token is set
    if [[ -z "${K3S_TOKEN:-}" ]]; then
        log_error "K3S_TOKEN environment variable is not set"
    else
        log_info "K3S_TOKEN is set (length: ${#K3S_TOKEN} characters)"
    fi
    
    # Check if URL is set
    if [[ -z "${K3S_URL:-}" ]]; then
        log_error "K3S_URL environment variable is not set"
    else
        log_info "K3S_URL is set: ${K3S_URL}"
    fi
    
    # Check for firewall
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log_warn "UFW firewall is active - may need to allow k3s ports"
    fi
    
    log_error "=========================================="
    log_error "Troubleshooting commands:"
    log_error "  systemctl status k3s-agent.service"
    log_error "  journalctl -xeu k3s-agent.service"
    log_error "  systemctl restart k3s-agent.service"
    log_error "=========================================="
}

