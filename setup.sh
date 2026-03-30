#!/bin/bash
# DevStack on Lima — One-Click Setup
# Usage: ./setup.sh [single|multi]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-multi}"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${BOLD}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1: Prerequisites
# ---------------------------------------------------------------------------
phase_prerequisites() {
    log "Phase 1: Checking prerequisites..."

    # macOS check
    [[ "$(uname)" == "Darwin" ]] || fail "This script requires macOS"

    # Architecture
    local arch
    arch=$(uname -m)
    [[ "$arch" == "arm64" ]] || warn "Tested on Apple Silicon (arm64), you have $arch"

    # Homebrew
    if ! command -v brew &>/dev/null; then
        log "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    ok "Homebrew"

    # Lima
    if ! command -v limactl &>/dev/null; then
        log "Installing Lima..."
        brew install lima
    fi
    ok "Lima $(limactl --version 2>&1 | head -1)"

    # socket_vmnet (required for multi-node)
    if [[ "$MODE" == "multi" ]]; then
        if ! brew list socket_vmnet &>/dev/null; then
            log "Installing socket_vmnet..."
            brew install socket_vmnet
        fi

        # Copy binary (Lima rejects symlinks)
        if [[ ! -f /opt/socket_vmnet/bin/socket_vmnet ]] || \
           [[ -L /opt/socket_vmnet/bin/socket_vmnet ]]; then
            log "Setting up socket_vmnet binary (requires sudo)..."
            sudo mkdir -p /opt/socket_vmnet/bin
            sudo rm -f /opt/socket_vmnet/bin/socket_vmnet
            sudo cp /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /opt/socket_vmnet/bin/socket_vmnet
        fi

        # Start service
        if ! sudo brew services list 2>/dev/null | grep -q "socket_vmnet.*started"; then
            log "Starting socket_vmnet service (requires sudo)..."
            sudo brew services start socket_vmnet 2>/dev/null || true
        fi

        # Lima sudoers
        if ! limactl sudoers &>/dev/null 2>&1; then
            log "Configuring Lima sudoers (requires sudo)..."
            limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null
        fi
        ok "socket_vmnet + sudoers"
    fi

    # Resource check
    local mem_gb
    mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    local cpus
    cpus=$(sysctl -n hw.ncpu)
    if [[ "$MODE" == "multi" ]]; then
        [[ $mem_gb -ge 20 ]] || warn "Recommended 20GB+ RAM for multi-node (you have ${mem_gb}GB)"
        [[ $cpus -ge 6 ]] || warn "Recommended 6+ CPUs for multi-node (you have $cpus)"
    else
        [[ $mem_gb -ge 16 ]] || warn "Recommended 16GB+ RAM for single mode (you have ${mem_gb}GB)"
    fi
    ok "Host resources: ${cpus} CPUs, ${mem_gb}GB RAM"
}

# ---------------------------------------------------------------------------
# Phase 2: Create VMs
# ---------------------------------------------------------------------------
phase_create_vms() {
    log "Phase 2: Creating VMs ($MODE mode)..."

    if [[ "$MODE" == "single" ]]; then
        create_vm "devstack" "$SCRIPT_DIR/configs/single/devstack.yaml"
    else
        create_vm "devstack-ctrl" "$SCRIPT_DIR/configs/multi/devstack-ctrl.yaml"
        create_vm "devstack-cp1"  "$SCRIPT_DIR/configs/multi/devstack-cp1.yaml"
        create_vm "devstack-cp2"  "$SCRIPT_DIR/configs/multi/devstack-cp2.yaml"
    fi
}

create_vm() {
    local name="$1" config="$2"
    if limactl list -q 2>/dev/null | grep -q "^${name}$"; then
        local status
        status=$(limactl list --format '{{.Status}}' "$name" 2>/dev/null || echo "unknown")
        if [[ "$status" == "Running" ]]; then
            ok "VM $name already running"
            return
        fi
        log "  Starting existing VM $name..."
        limactl start "$name" --tty=false
    else
        log "  Creating VM $name..."
        limactl start --name="$name" "$config" --tty=false
    fi
    ok "VM $name"
}

# ---------------------------------------------------------------------------
# Phase 3: Configure (multi-node only)
# ---------------------------------------------------------------------------
phase_configure() {
    if [[ "$MODE" != "multi" ]]; then return; fi

    log "Phase 3: Configuring multi-node networking..."

    local ctrl_ip cp1_ip cp2_ip
    ctrl_ip=$(limactl shell devstack-ctrl -- ip -4 addr show lima0 | awk '/inet / {split($2,a,"/"); print a[1]}')
    cp1_ip=$(limactl shell devstack-cp1 -- ip -4 addr show lima0 | awk '/inet / {split($2,a,"/"); print a[1]}')
    cp2_ip=$(limactl shell devstack-cp2 -- ip -4 addr show lima0 | awk '/inet / {split($2,a,"/"); print a[1]}')

    log "  IPs: ctrl=$ctrl_ip  cp1=$cp1_ip  cp2=$cp2_ip"

    # Inject controller IP into compute nodes
    for vm in devstack-cp1 devstack-cp2; do
        limactl shell "$vm" -- sudo sed -i "s/CONTROLLER_IP_PLACEHOLDER/$ctrl_ip/g" /opt/stack/devstack/local.conf
    done
    ok "Controller IP injected into compute nodes"

    # Save IPs for later
    echo "$ctrl_ip" > /tmp/devstack-lima-ctrl-ip
}

# ---------------------------------------------------------------------------
# Phase 4: Install DevStack (stack.sh)
# ---------------------------------------------------------------------------
phase_install() {
    log "Phase 4: Installing DevStack (this takes 30-60 minutes)..."

    if [[ "$MODE" == "single" ]]; then
        run_stack "devstack"
    else
        run_stack "devstack-ctrl"
        # Compute nodes can run in parallel after controller is done
        run_stack "devstack-cp1" &
        local pid1=$!
        run_stack "devstack-cp2" &
        local pid2=$!

        log "  Waiting for compute nodes (running in parallel)..."
        local failed=0
        wait "$pid1" || { warn "devstack-cp1 stack.sh failed"; failed=1; }
        wait "$pid2" || { warn "devstack-cp2 stack.sh failed"; failed=1; }
        [[ $failed -eq 0 ]] || fail "Compute node installation failed. Check logs with: ./ds ssh <vm> -- cat /opt/stack/logs/stack.sh.log"
    fi
}

run_stack() {
    local vm="$1"
    local start_time
    start_time=$(date +%s)

    log "  Installing on $vm..."
    if limactl shell "$vm" -- sudo -iu stack bash -c 'cd /opt/stack/devstack && ./stack.sh' \
        > "/tmp/devstack-lima-${vm}.log" 2>&1; then
        local elapsed=$(( $(date +%s) - start_time ))
        ok "$vm completed ($(( elapsed / 60 ))m $(( elapsed % 60 ))s)"
    else
        local elapsed=$(( $(date +%s) - start_time ))
        warn "$vm failed after $(( elapsed / 60 ))m. Log: /tmp/devstack-lima-${vm}.log"
        # Show last error
        tail -5 "/tmp/devstack-lima-${vm}.log" | grep -i "error\|fail" || true
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Phase 5: Post-Setup (multi-node only)
# ---------------------------------------------------------------------------
phase_post_setup() {
    if [[ "$MODE" != "multi" ]]; then return; fi

    log "Phase 5: Post-setup fixes for ARM/libvirt/cell..."
    "$SCRIPT_DIR/ds" post-setup multi
}

# ---------------------------------------------------------------------------
# Phase 6: Validate
# ---------------------------------------------------------------------------
phase_validate() {
    log "Phase 6: Validating installation..."
    "$SCRIPT_DIR/ds" validate "$MODE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}========================================${RESET}"
    echo -e "${BOLD}  DevStack on Lima — Automated Setup${RESET}"
    echo -e "${BOLD}  Mode: $MODE${RESET}"
    echo -e "${BOLD}========================================${RESET}"
    echo ""

    case "$MODE" in
        single|multi) ;;
        *) echo "Usage: $0 [single|multi]"; exit 1 ;;
    esac

    local total_start
    total_start=$(date +%s)

    phase_prerequisites
    echo ""
    phase_create_vms
    echo ""
    phase_configure
    echo ""
    phase_install
    echo ""
    phase_post_setup
    echo ""
    phase_validate

    local total_elapsed=$(( $(date +%s) - total_start ))
    echo ""
    echo -e "${GREEN}${BOLD}========================================${RESET}"
    echo -e "${GREEN}${BOLD}  Setup complete! ($(( total_elapsed / 60 ))m $(( total_elapsed % 60 ))s)${RESET}"
    echo -e "${GREEN}${BOLD}========================================${RESET}"
    echo ""
    echo "Quick reference:"
    echo "  ./ds status             — VM status"
    echo "  ./ds ssh <vm>           — SSH into VM"
    echo "  ./ds validate $MODE    — Re-run validation"
    echo "  ./ds down $MODE        — Stop VMs"
    echo "  ./ds up $MODE          — Start VMs again"

    if [[ "$MODE" == "multi" ]] && [[ -f /tmp/devstack-lima-ctrl-ip ]]; then
        local ctrl_ip
        ctrl_ip=$(cat /tmp/devstack-lima-ctrl-ip)
        echo ""
        echo "OpenStack endpoints:"
        echo "  Keystone: http://$ctrl_ip:5000/v3"
        echo "  Nova:     http://$ctrl_ip:8774/v2.1"
        echo "  Neutron:  http://$ctrl_ip:9696"
        echo "  Glance:   http://$ctrl_ip:9292"
        echo ""
        echo "Credentials: admin / secret"
    fi
}

main
