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
        local install_cmd="curl -sfL ${K3S_INSTALL_SCRIPT} | INSTALL_K3S_EXEC='--disable traefik ${additional_flags}' sh -"
        log_info "Executing: ${install_cmd}"
        if eval "$install_cmd"; then
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
            log_info "k3s agent installation completed successfully"
        else
            log_error "k3s agent installation failed"
            exit 1
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

