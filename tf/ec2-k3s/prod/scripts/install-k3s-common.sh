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

# Install prerequisites (curl, git, awscli, kernel parameters)
install_k3s_prerequisites() {
    log_info "Installing prerequisites (curl, git, awscli)..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq; then
        log_error "Failed to update package list"
        exit 1
    fi
    
    if ! apt-get install -y -qq curl git > /dev/null; then
        log_error "Failed to install curl and git"
        exit 1
    fi
    
    # Install AWS CLI v2 if not already installed
    # Set default installation directory (used in error diagnostics)
    local AWS_CLI_INSTALL_DIR="/usr/local/aws-cli"
    
    if ! command -v aws &> /dev/null; then
        log_info "Installing AWS CLI v2..."
        
        # Pre-installation diagnostic logging
        log_info "Pre-installation diagnostics:"
        log_info "  Current PATH: ${PATH}"
        log_info "  Current user: $(whoami)"
        log_info "  Current working directory: $(pwd)"
        
        # Check /usr/local/bin directory
        if [[ -d "/usr/local/bin" ]]; then
            log_info "  /usr/local/bin exists"
            log_info "  /usr/local/bin permissions: $(stat -c '%a %U:%G' /usr/local/bin 2>/dev/null || stat -f '%A %Su:%Sg' /usr/local/bin 2>/dev/null || echo 'unknown')"
            if [[ -w "/usr/local/bin" ]]; then
                log_info "  /usr/local/bin is writable"
            else
                log_warn "  /usr/local/bin is NOT writable"
            fi
        else
            log_warn "  /usr/local/bin does not exist, will be created"
        fi
        
        # Check disk space
        local available_space
        available_space=$(df -h /usr/local 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
        log_info "  Available disk space in /usr/local: ${available_space}"
        
        # Check for existing AWS CLI installations
        local existing_aws
        existing_aws=$(find /usr/local /usr/bin /usr/sbin -name aws -type f 2>/dev/null | head -5 || true)
        if [[ -n "$existing_aws" ]]; then
            log_warn "  Found existing AWS CLI installations:"
            echo "$existing_aws" | while read -r path; do
                log_warn "    - $path"
            done
        else
            log_info "  No existing AWS CLI installations found"
        fi
        
        local AWS_CLI_TMP="/tmp/awscli.tar.gz"
        local AWS_CLI_INSTALL_LOG="/tmp/awscli-install.log"
        
        # Detect CPU architecture for AWS CLI download
        ARCH="$(uname -m)"
        log_info "Detected CPU architecture: $ARCH"
        case "$ARCH" in
          x86_64)
            AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
            ;;
          aarch64|arm64)
            AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
            ;;
          *)
            log_error "Unsupported architecture for AWS CLI: $ARCH"
            exit 1
            ;;
        esac
        log_info "AWS CLI download URL: $AWSCLI_URL"
        
        # Download AWS CLI v2
        log_info "Downloading AWS CLI v2 from $AWSCLI_URL..."
        if ! curl -fsSL "$AWSCLI_URL" -o /tmp/awscliv2.zip; then
            log_error "Failed to download AWS CLI v2 from $AWSCLI_URL"
            exit 1
        fi
        
        # Verify download
        if [[ ! -f /tmp/awscliv2.zip ]]; then
            log_error "Downloaded file /tmp/awscliv2.zip does not exist"
            exit 1
        fi
        
        local zip_size
        zip_size=$(stat -c%s /tmp/awscliv2.zip 2>/dev/null || stat -f%z /tmp/awscliv2.zip 2>/dev/null || echo "unknown")
        log_info "Downloaded file size: ${zip_size} bytes ($(numfmt --to=iec-i --suffix=B ${zip_size} 2>/dev/null || echo 'unknown'))"
        
        if [[ "$zip_size" -lt 1000 ]]; then
            log_error "Downloaded file is suspiciously small (${zip_size} bytes), download may have failed"
            log_error "File contents:"
            head -20 /tmp/awscliv2.zip 2>/dev/null || true
            exit 1
        fi
        
        # Install unzip if not available
        if ! command -v unzip &> /dev/null; then
            log_info "Installing unzip package..."
            if ! apt-get install -y -qq unzip > /dev/null; then
                log_error "Failed to install unzip"
                exit 1
            fi
            log_info "unzip installed successfully"
        else
            log_info "unzip already available: $(command -v unzip)"
        fi
        
        # Extract AWS CLI
        log_info "Extracting AWS CLI installer..."
        if ! unzip -q /tmp/awscliv2.zip -d /tmp; then
            log_error "Failed to extract AWS CLI installer from /tmp/awscliv2.zip"
            exit 1
        fi
        
        # Verify extraction
        if [[ ! -f /tmp/aws/install ]]; then
            log_error "Extraction failed: /tmp/aws/install not found"
            log_error "Contents of /tmp/aws:"
            ls -la /tmp/aws 2>/dev/null || true
            exit 1
        fi
        
        log_info "Extraction successful, installer found at /tmp/aws/install"
        log_info "Installer permissions: $(stat -c '%a %U:%G' /tmp/aws/install 2>/dev/null || stat -f '%A %Su:%Sg' /tmp/aws/install 2>/dev/null || echo 'unknown')"
        
        # Run AWS CLI installer with logging
        log_info "Running AWS CLI installer..."
        log_info "  Installation directory: $AWS_CLI_INSTALL_DIR"
        log_info "  Binary directory: /usr/local/bin"
        log_info "  Installer log: $AWS_CLI_INSTALL_LOG"
        
        # Clear any existing log file
        > "$AWS_CLI_INSTALL_LOG"
        
        # Run installer and capture output
        local install_exit_code=0
        if ! /tmp/aws/install -i "$AWS_CLI_INSTALL_DIR" -b /usr/local/bin > "$AWS_CLI_INSTALL_LOG" 2>&1; then
            install_exit_code=$?
        fi
        
        # Log installer output
        if [[ -s "$AWS_CLI_INSTALL_LOG" ]]; then
            log_info "Installer output:"
            while IFS= read -r line; do
                log_info "  $line"
            done < "$AWS_CLI_INSTALL_LOG"
        else
            log_warn "Installer produced no output"
        fi
        
        # Check installer exit code
        if [[ $install_exit_code -ne 0 ]]; then
            log_error "AWS CLI installer failed with exit code: $install_exit_code"
            log_error "Full installer log:"
            cat "$AWS_CLI_INSTALL_LOG" || true
            exit 1
        fi
        
        log_info "AWS CLI installer completed successfully (exit code: $install_exit_code)"
        
        # Post-installation diagnostic logging
        log_info "Post-installation diagnostics:"
        
        # Check what was created in installation directory
        if [[ -d "$AWS_CLI_INSTALL_DIR" ]]; then
            log_info "  Installation directory $AWS_CLI_INSTALL_DIR exists"
            local install_dir_size
            install_dir_size=$(du -sh "$AWS_CLI_INSTALL_DIR" 2>/dev/null | cut -f1 || echo "unknown")
            log_info "  Installation directory size: ${install_dir_size}"
            log_info "  Contents of installation directory:"
            ls -la "$AWS_CLI_INSTALL_DIR" 2>/dev/null | head -10 | while IFS= read -r line; do
                log_info "    $line"
            done || true
        else
            log_warn "  Installation directory $AWS_CLI_INSTALL_DIR does not exist"
        fi
        
        # Check what was created in binary directory
        log_info "  Checking /usr/local/bin for AWS CLI files:"
        local bin_files
        bin_files=$(ls -la /usr/local/bin/aws* 2>/dev/null || true)
        if [[ -n "$bin_files" ]]; then
            echo "$bin_files" | while IFS= read -r line; do
                log_info "    $line"
            done
        else
            log_warn "    No aws* files found in /usr/local/bin"
        fi
        
        # Check for symlinks
        if [[ -L /usr/local/bin/aws ]]; then
            log_info "  /usr/local/bin/aws is a symlink"
            log_info "  Symlink target: $(readlink -f /usr/local/bin/aws 2>/dev/null || echo 'unknown')"
            if [[ ! -e /usr/local/bin/aws ]]; then
                log_error "  Symlink is broken (target does not exist)"
            fi
        elif [[ -f /usr/local/bin/aws ]]; then
            log_info "  /usr/local/bin/aws is a regular file"
        fi
        
        # Cleanup
        log_info "Cleaning up temporary files..."
        rm -rf /tmp/aws /tmp/awscliv2.zip "$AWS_CLI_INSTALL_LOG"
        log_info "Cleanup completed"
        
        log_info "AWS CLI v2 installed successfully"
    else
        local existing_aws_path
        existing_aws_path=$(command -v aws)
        log_info "AWS CLI already installed at: $existing_aws_path"
        log_info "AWS CLI version: $(aws --version 2>&1 | head -n1 || echo 'unknown')"
    fi
    
    # Verify AWS CLI binary exists and is executable
    AWS_BIN="/usr/local/bin/aws"
    
    if [[ ! -x "$AWS_BIN" ]]; then
        log_error "AWS CLI binary not found at expected path: $AWS_BIN"
        log_error "Comprehensive diagnostics:"
        
        # Check if file exists but not executable
        if [[ -f "$AWS_BIN" ]]; then
            log_error "  File exists but is not executable"
            log_error "  File permissions: $(stat -c '%a %U:%G' "$AWS_BIN" 2>/dev/null || stat -f '%A %Su:%Sg' "$AWS_BIN" 2>/dev/null || echo 'unknown')"
            log_error "  File type: $(file "$AWS_BIN" 2>/dev/null || echo 'unknown')"
        elif [[ -L "$AWS_BIN" ]]; then
            log_error "  Symlink exists at $AWS_BIN"
            log_error "  Symlink target: $(readlink "$AWS_BIN" 2>/dev/null || echo 'unknown')"
            if [[ ! -e "$AWS_BIN" ]]; then
                log_error "  Symlink is broken (target does not exist)"
            fi
        else
            log_error "  File does not exist at $AWS_BIN"
        fi
        
        # Check installation directory
        if [[ -d "$AWS_CLI_INSTALL_DIR" ]]; then
            log_error "  Installation directory $AWS_CLI_INSTALL_DIR exists:"
            log_error "    Contents:"
            ls -la "$AWS_CLI_INSTALL_DIR" 2>/dev/null | head -20 | while IFS= read -r line; do
                log_error "      $line"
            done || true
            
            # Look for aws binary in installation directory
            local aws_in_install_dir
            aws_in_install_dir=$(find "$AWS_CLI_INSTALL_DIR" -name aws -type f 2>/dev/null | head -5 || true)
            if [[ -n "$aws_in_install_dir" ]]; then
                log_error "    Found aws binary in installation directory:"
                echo "$aws_in_install_dir" | while read -r path; do
                    log_error "      - $path (executable: $([ -x "$path" ] && echo 'yes' || echo 'no'))"
                done
            fi
        else
            log_error "  Installation directory $AWS_CLI_INSTALL_DIR does not exist"
        fi
        
        # Check /usr/local/bin directory
        log_error "  /usr/local/bin directory status:"
        if [[ -d /usr/local/bin ]]; then
            log_error "    Directory exists"
            log_error "    Permissions: $(stat -c '%a %U:%G' /usr/local/bin 2>/dev/null || stat -f '%A %Su:%Sg' /usr/local/bin 2>/dev/null || echo 'unknown')"
            log_error "    Writable: $([ -w /usr/local/bin ] && echo 'yes' || echo 'no')"
            log_error "    Contents (first 20 items):"
            ls -la /usr/local/bin 2>/dev/null | head -20 | while IFS= read -r line; do
                log_error "      $line"
            done || true
        else
            log_error "    Directory does not exist"
        fi
        
        # Search for aws binary
        log_error "  Searching for aws binary in common locations:"
        local found_aws
        found_aws=$(find /usr/local /usr/bin /usr/sbin -name aws -type f 2>/dev/null | head -10 || true)
        if [[ -n "$found_aws" ]]; then
            log_error "    Found aws binaries:"
            echo "$found_aws" | while read -r path; do
                local is_executable
                is_executable=$([ -x "$path" ] && echo 'yes' || echo 'no')
                log_error "      - $path (executable: $is_executable)"
            done
        else
            log_error "    No aws binary found in common locations"
        fi
        
        # Check PATH
        log_error "  Current PATH: ${PATH}"
        log_error "  /usr/local/bin in PATH: $([[ ":$PATH:" == *":/usr/local/bin:"* ]] && echo 'yes' || echo 'no')"
        
        exit 1
    fi
    
    # Export AWS_BIN for use in calling scripts
    export AWS_BIN
    AWS_CLI_VERSION=$("$AWS_BIN" --version 2>&1 | head -n1)
    log_info "AWS CLI verified at: $AWS_BIN ($AWS_CLI_VERSION)"
    
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
        log_warn "k3s already installed — forcing uninstall to ensure deterministic configuration"
        if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
            /usr/local/bin/k3s-uninstall.sh || true
        fi
        rm -rf /etc/rancher /var/lib/rancher
    fi
    
    log_info "Installing k3s as ${k3s_mode}..."
    
    if [[ "$k3s_mode" == "server" ]]; then
        # Construct the k3s exec flags
        local k3s_exec_flags="--disable traefik"
        if [[ -n "$additional_flags" ]]; then
            k3s_exec_flags="${k3s_exec_flags} ${additional_flags}"
        fi
        
        log_info "Installing k3s with flags: ${k3s_exec_flags}"
        
        # Export INSTALL_K3S_EXEC before the pipeline so it reaches the installer shell
        export INSTALL_K3S_EXEC="${k3s_exec_flags}"
        log_info "Exported INSTALL_K3S_EXEC=${INSTALL_K3S_EXEC}"
        
        if curl -sfL "${K3S_INSTALL_SCRIPT}" | sh -; then
            log_info "k3s installation command completed successfully"
        else
            log_error "k3s installation command failed"
            exit 1
        fi
        
        unset INSTALL_K3S_EXEC
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

# Verify that Traefik is disabled
verify_traefik_disabled() {
    log_info "Verifying that Traefik is disabled..."

    # Check for Traefik helmchart in kube-system namespace
    # If helmcharts CRD doesn't exist or command fails, we assume Traefik is not present
    local helmcharts_output
    helmcharts_output=$(k3s kubectl get helmcharts -n kube-system 2>/dev/null || true)
    
    if echo "$helmcharts_output" | grep -qi traefik; then
        log_error "Traefik helmchart detected — disable flag failed"
        k3s kubectl get helmcharts -n kube-system || true
        exit 1
    fi

    log_info "✓ Traefik is not present"
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

