#!/usr/bin/env bash
# ============================================================================
#  WebApp Pentest Lab Setup Script
#  Author: WC Security (wescastle.com)
#  Repo:   github.com/SkyzFallin/webapp-pentest-lab
#  
#  Deploys a complete web application penetration testing lab environment
#  with vulnerable targets, scanning tools, and wordlists.
#
#  Tested on: Ubuntu 22.04/24.04, Debian 12, Kali Linux 2024+
#  Requires:  sudo/root access, internet connection
# ============================================================================

set -euo pipefail

# ============================================================================
#  Configuration — edit these to customize your lab
# ============================================================================

DVWA_PORT=8080
JUICESHOP_PORT=3000
FFUF_VERSION="2.1.0"
NUCLEI_VERSION="3.3.7"
INSTALL_DIR="/opt/webapp-pentest-lab"
LOG_FILE="/tmp/webapp-pentest-lab-install.log"

# Docker images
DVWA_IMAGE="vulnerables/web-dvwa:latest"
JUICESHOP_IMAGE="bkimminich/juice-shop:latest"

# ============================================================================
#  Color & formatting helpers
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          WebApp Pentest Lab Setup Script v1.0               ║"
    echo "║          WC Security — wescastle.com                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
step()    { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}\n"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# ============================================================================
#  Pre-flight checks
# ============================================================================

preflight() {
    banner
    step "Pre-flight Checks"

    # Root / sudo check
    if [[ $EUID -ne 0 ]]; then
        if ! sudo -v 2>/dev/null; then
            error "This script requires root or sudo privileges."
            exit 1
        fi
        SUDO="sudo"
    else
        SUDO=""
    fi
    success "Privileges: OK"

    # OS detection
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_NAME="unknown"
    fi
    info "Detected OS: ${OS_NAME}"

    # Check supported OS
    case "$OS_ID" in
        ubuntu|debian|kali) success "Supported OS: ${OS_ID}" ;;
        fedora|rhel|centos|rocky|alma)
            warn "RPM-based OS detected — this script targets Debian/Ubuntu/Kali."
            warn "Package commands will be adapted but may need manual adjustment."
            PKG_MANAGER="dnf"
            ;;
        *)
            warn "Unrecognized OS '${OS_ID}'. Proceeding with Debian-style commands."
            ;;
    esac

    # Architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_LABEL="amd64" ;;
        aarch64) ARCH_LABEL="arm64" ;;
        *)       error "Unsupported architecture: ${ARCH}"; exit 1 ;;
    esac
    info "Architecture: ${ARCH} (${ARCH_LABEL})"

    # Disk space check (need ~5GB minimum)
    AVAIL_KB=$(df / | awk 'NR==2 {print $4}')
    AVAIL_GB=$((AVAIL_KB / 1048576))
    if [[ $AVAIL_GB -lt 5 ]]; then
        warn "Low disk space: ${AVAIL_GB}GB available (recommend 5GB+)"
    else
        success "Disk space: ${AVAIL_GB}GB available"
    fi

    # RAM check
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1048576))
    if [[ $TOTAL_RAM_GB -lt 2 ]]; then
        warn "Low RAM: ${TOTAL_RAM_GB}GB (recommend 4GB+). Juice Shop may be slow."
    else
        success "RAM: ${TOTAL_RAM_GB}GB"
    fi

    # Internet connectivity
    if curl -s --connect-timeout 5 https://registry-1.docker.io/v2/ >/dev/null 2>&1 || \
       curl -s --connect-timeout 5 https://github.com >/dev/null 2>&1; then
        success "Internet connectivity: OK"
    else
        error "No internet connection detected. This script requires internet access."
        exit 1
    fi

    echo ""
    log "Pre-flight passed: OS=${OS_NAME}, Arch=${ARCH_LABEL}, Disk=${AVAIL_GB}GB, RAM=${TOTAL_RAM_GB}GB"
}

# ============================================================================
#  Helper: check if a command exists
# ============================================================================

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================================
#  Package manager abstraction
# ============================================================================

pkg_update() {
    info "Updating package lists..."
    $SUDO apt-get update -qq >> "$LOG_FILE" 2>&1
    success "Package lists updated"
}

pkg_install() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        success "${pkg} is already installed"
        return 0
    fi
    info "Installing ${pkg}..."
    $SUDO apt-get install -y -qq "$pkg" >> "$LOG_FILE" 2>&1
    if [[ $? -eq 0 ]]; then
        success "${pkg} installed"
    else
        error "Failed to install ${pkg} — check ${LOG_FILE}"
        return 1
    fi
}

# ============================================================================
#  Install: Docker
# ============================================================================

install_docker() {
    step "Docker Engine"

    if cmd_exists docker; then
        DOCKER_VER=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        success "Docker already installed (v${DOCKER_VER})"
    else
        info "Installing Docker..."
        pkg_install docker.io
    fi

    # Ensure Docker daemon is running
    if ! $SUDO systemctl is-active --quiet docker 2>/dev/null; then
        info "Starting Docker daemon..."
        $SUDO systemctl start docker >> "$LOG_FILE" 2>&1
        $SUDO systemctl enable docker >> "$LOG_FILE" 2>&1
        success "Docker daemon started and enabled"
    else
        success "Docker daemon is running"
    fi

    # Add current user to docker group (if not root)
    if [[ $EUID -ne 0 ]]; then
        if ! groups "$USER" | grep -q docker; then
            info "Adding ${USER} to docker group..."
            $SUDO usermod -aG docker "$USER"
            warn "You may need to log out and back in for docker group membership to take effect."
            warn "Until then, containers will be launched with sudo."
        else
            success "${USER} is in docker group"
        fi
    fi

    # Install docker-compose if missing
    if cmd_exists docker-compose || docker compose version >/dev/null 2>&1; then
        success "Docker Compose available"
    else
        pkg_install docker-compose
    fi
}

# ============================================================================
#  Install: Core pentest tools
# ============================================================================

install_tools() {
    step "Pentest Tools"

    # --- Burp Suite ---
    if cmd_exists burpsuite; then
        success "Burp Suite: installed"
    else
        warn "Burp Suite not found — install manually from https://portswigger.net/burp/releases"
        warn "  (Community edition is free)"
    fi

    # --- sqlmap ---
    if cmd_exists sqlmap; then
        success "sqlmap: installed"
    else
        info "Installing sqlmap..."
        pkg_install sqlmap
    fi

    # --- gobuster ---
    if cmd_exists gobuster; then
        success "gobuster: installed"
    else
        info "Installing gobuster..."
        pkg_install gobuster
    fi

    # --- nikto ---
    if cmd_exists nikto; then
        success "nikto: installed"
    else
        info "Installing nikto..."
        pkg_install nikto
    fi

    # --- curl & wget (usually present, but just in case) ---
    for tool in curl wget unzip; do
        if cmd_exists "$tool"; then
            success "${tool}: installed"
        else
            pkg_install "$tool"
        fi
    done

    # --- ffuf (binary release) ---
    if cmd_exists ffuf; then
        FFUF_VER=$(ffuf -V 2>&1 | grep -oP '\d+\.\d+\.\d+' || echo "installed")
        success "ffuf: v${FFUF_VER}"
    else
        info "Installing ffuf v${FFUF_VERSION}..."
        FFUF_URL="https://github.com/ffuf/ffuf/releases/download/v${FFUF_VERSION}/ffuf_${FFUF_VERSION}_linux_${ARCH_LABEL}.tar.gz"
        TMP_DIR=$(mktemp -d)
        if curl -sL "$FFUF_URL" -o "${TMP_DIR}/ffuf.tar.gz" >> "$LOG_FILE" 2>&1; then
            tar xzf "${TMP_DIR}/ffuf.tar.gz" -C "${TMP_DIR}" ffuf 2>> "$LOG_FILE"
            $SUDO mv "${TMP_DIR}/ffuf" /usr/local/bin/ffuf
            $SUDO chmod +x /usr/local/bin/ffuf
            rm -rf "${TMP_DIR}"
            success "ffuf v${FFUF_VERSION} installed"
        else
            error "Failed to download ffuf — check ${LOG_FILE}"
            rm -rf "${TMP_DIR}"
        fi
    fi

    # --- nuclei (binary release) ---
    if cmd_exists nuclei; then
        NUCLEI_VER=$(nuclei -version 2>&1 | grep -oP 'v\d+\.\d+\.\d+' || echo "installed")
        success "nuclei: ${NUCLEI_VER}"
    else
        info "Installing nuclei v${NUCLEI_VERSION}..."
        NUCLEI_URL="https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/nuclei_${NUCLEI_VERSION}_linux_${ARCH_LABEL}.zip"
        TMP_DIR=$(mktemp -d)
        if curl -sL "$NUCLEI_URL" -o "${TMP_DIR}/nuclei.zip" >> "$LOG_FILE" 2>&1; then
            unzip -o "${TMP_DIR}/nuclei.zip" nuclei -d "${TMP_DIR}" >> "$LOG_FILE" 2>&1
            $SUDO mv "${TMP_DIR}/nuclei" /usr/local/bin/nuclei
            $SUDO chmod +x /usr/local/bin/nuclei
            rm -rf "${TMP_DIR}"
            success "nuclei v${NUCLEI_VERSION} installed"
        else
            error "Failed to download nuclei — check ${LOG_FILE}"
            rm -rf "${TMP_DIR}"
        fi
    fi
}

# ============================================================================
#  Install: Wordlists
# ============================================================================

install_wordlists() {
    step "Wordlists"

    # SecLists
    if [[ -d /usr/share/seclists ]] || [[ -d /usr/share/SecLists ]]; then
        success "SecLists: already present"
    else
        info "Installing SecLists (this may take a minute)..."
        if pkg_install seclists 2>/dev/null; then
            success "SecLists installed via package manager"
        else
            warn "SecLists not available as package — cloning from GitHub..."
            $SUDO git clone --depth 1 https://github.com/danielmiessler/SecLists.git /usr/share/seclists >> "$LOG_FILE" 2>&1
            success "SecLists cloned to /usr/share/seclists"
        fi
    fi

    # dirb wordlists
    if [[ -d /usr/share/dirb/wordlists ]] || [[ -f /usr/share/dirb/wordlists/common.txt ]]; then
        success "dirb wordlists: present"
    else
        info "Installing dirb (includes wordlists)..."
        pkg_install dirb
    fi
}

# ============================================================================
#  Deploy: Vulnerable targets
# ============================================================================

deploy_targets() {
    step "Vulnerable Lab Targets"

    # Use sudo for docker if user isn't in docker group yet
    if groups "$USER" 2>/dev/null | grep -q docker; then
        DOCKER_CMD="docker"
    else
        DOCKER_CMD="$SUDO docker"
    fi

    # --- DVWA ---
    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q '^dvwa$'; then
        if $DOCKER_CMD ps --format '{{.Names}}' | grep -q '^dvwa$'; then
            success "DVWA: already running on port ${DVWA_PORT}"
        else
            info "Starting existing DVWA container..."
            $DOCKER_CMD start dvwa >> "$LOG_FILE" 2>&1
            success "DVWA started on port ${DVWA_PORT}"
        fi
    else
        info "Pulling DVWA image..."
        $DOCKER_CMD pull "$DVWA_IMAGE" >> "$LOG_FILE" 2>&1
        info "Launching DVWA on port ${DVWA_PORT}..."
        $DOCKER_CMD run -d \
            --name dvwa \
            -p "${DVWA_PORT}:80" \
            --restart unless-stopped \
            "$DVWA_IMAGE" >> "$LOG_FILE" 2>&1
        success "DVWA deployed on port ${DVWA_PORT}"
    fi

    # --- OWASP Juice Shop ---
    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q '^juiceshop$'; then
        if $DOCKER_CMD ps --format '{{.Names}}' | grep -q '^juiceshop$'; then
            success "Juice Shop: already running on port ${JUICESHOP_PORT}"
        else
            info "Starting existing Juice Shop container..."
            $DOCKER_CMD start juiceshop >> "$LOG_FILE" 2>&1
            success "Juice Shop started on port ${JUICESHOP_PORT}"
        fi
    else
        info "Pulling Juice Shop image (this may take a few minutes)..."
        $DOCKER_CMD pull "$JUICESHOP_IMAGE" >> "$LOG_FILE" 2>&1
        info "Launching Juice Shop on port ${JUICESHOP_PORT}..."
        $DOCKER_CMD run -d \
            --name juiceshop \
            -p "${JUICESHOP_PORT}:3000" \
            --restart unless-stopped \
            "$JUICESHOP_IMAGE" >> "$LOG_FILE" 2>&1
        success "Juice Shop deployed on port ${JUICESHOP_PORT}"
    fi

    # Wait for containers to become healthy
    info "Waiting for targets to come online..."
    sleep 5

    # Verify
    local dvwa_status juiceshop_status
    dvwa_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${DVWA_PORT}/" 2>/dev/null || echo "000")
    juiceshop_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${JUICESHOP_PORT}/" 2>/dev/null || echo "000")

    if [[ "$dvwa_status" == "200" ]] || [[ "$dvwa_status" == "302" ]]; then
        success "DVWA responding (HTTP ${dvwa_status})"
    else
        warn "DVWA not responding yet (HTTP ${dvwa_status}) — may need a moment to initialize"
    fi

    if [[ "$juiceshop_status" == "200" ]]; then
        success "Juice Shop responding (HTTP ${juiceshop_status})"
    else
        warn "Juice Shop not responding yet (HTTP ${juiceshop_status}) — may need a moment to initialize"
    fi
}

# ============================================================================
#  Generate: docker-compose.yml for easy management
# ============================================================================

generate_compose() {
    step "Docker Compose File"

    $SUDO mkdir -p "$INSTALL_DIR"

    cat > /tmp/docker-compose-lab.yml << 'COMPOSE'
# ============================================================================
#  WebApp Pentest Lab — Docker Compose
#  Usage: docker compose up -d
#         docker compose down
#         docker compose logs -f
# ============================================================================

services:
  dvwa:
    image: vulnerables/web-dvwa:latest
    container_name: dvwa
    ports:
      - "${DVWA_PORT:-8080}:80"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/login.php"]
      interval: 30s
      timeout: 10s
      retries: 3

  juiceshop:
    image: bkimminich/juice-shop:latest
    container_name: juiceshop
    ports:
      - "${JUICESHOP_PORT:-3000}:3000"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3
COMPOSE

    $SUDO mv /tmp/docker-compose-lab.yml "${INSTALL_DIR}/docker-compose.yml"
    success "docker-compose.yml written to ${INSTALL_DIR}/docker-compose.yml"
}

# ============================================================================
#  Generate: lab management helper script
# ============================================================================

generate_lab_manager() {
    cat > /tmp/lab.sh << 'LABSCRIPT'
#!/usr/bin/env bash
# Lab management helper — source this or run directly
# Usage: ./lab.sh [start|stop|status|reset|destroy]

DVWA_PORT="${DVWA_PORT:-8080}"
JUICESHOP_PORT="${JUICESHOP_PORT:-3000}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

case "${1:-status}" in
    start)
        echo -e "${CYAN}[*]${NC} Starting lab targets..."
        docker start dvwa juiceshop 2>/dev/null || {
            echo -e "${YELLOW}[!]${NC} Containers not found. Run the setup script first."
            exit 1
        }
        echo -e "${GREEN}[✓]${NC} Lab started"
        echo -e "    DVWA:       http://localhost:${DVWA_PORT}"
        echo -e "    Juice Shop: http://localhost:${JUICESHOP_PORT}"
        ;;
    stop)
        echo -e "${CYAN}[*]${NC} Stopping lab targets..."
        docker stop dvwa juiceshop 2>/dev/null
        echo -e "${GREEN}[✓]${NC} Lab stopped"
        ;;
    status)
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       WebApp Pentest Lab Status      ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        for name in dvwa juiceshop; do
            state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "not found")
            if [[ "$state" == "running" ]]; then
                echo -e "  ${GREEN}●${NC} ${name}: running"
            elif [[ "$state" == "exited" ]]; then
                echo -e "  ${RED}●${NC} ${name}: stopped"
            else
                echo -e "  ${YELLOW}●${NC} ${name}: ${state}"
            fi
        done
        echo ""
        echo -e "  DVWA:       http://localhost:${DVWA_PORT}  (admin / password)"
        echo -e "  Juice Shop: http://localhost:${JUICESHOP_PORT}  (register an account)"
        echo ""
        echo -e "  ${CYAN}Tools:${NC}"
        for tool in burpsuite sqlmap gobuster nikto ffuf nuclei; do
            if command -v "$tool" >/dev/null 2>&1; then
                echo -e "    ${GREEN}✓${NC} ${tool}"
            else
                echo -e "    ${RED}✗${NC} ${tool}"
            fi
        done
        ;;
    reset)
        echo -e "${YELLOW}[!]${NC} Resetting lab targets (all data will be lost)..."
        docker stop dvwa juiceshop 2>/dev/null
        docker rm dvwa juiceshop 2>/dev/null
        echo -e "${CYAN}[*]${NC} Re-deploying fresh containers..."
        docker run -d --name dvwa -p "${DVWA_PORT}:80" --restart unless-stopped vulnerables/web-dvwa:latest
        docker run -d --name juiceshop -p "${JUICESHOP_PORT}:3000" --restart unless-stopped bkimminich/juice-shop:latest
        echo -e "${GREEN}[✓]${NC} Lab reset complete"
        ;;
    destroy)
        echo -e "${RED}[!]${NC} Destroying lab (removing containers and images)..."
        docker stop dvwa juiceshop 2>/dev/null
        docker rm dvwa juiceshop 2>/dev/null
        docker rmi vulnerables/web-dvwa:latest bkimminich/juice-shop:latest 2>/dev/null
        echo -e "${GREEN}[✓]${NC} Lab destroyed"
        ;;
    *)
        echo "Usage: $0 {start|stop|status|reset|destroy}"
        exit 1
        ;;
esac
LABSCRIPT

    $SUDO mv /tmp/lab.sh "${INSTALL_DIR}/lab.sh"
    $SUDO chmod +x "${INSTALL_DIR}/lab.sh"
    success "Lab manager written to ${INSTALL_DIR}/lab.sh"
}

# ============================================================================
#  Summary
# ============================================================================

print_summary() {
    step "Setup Complete"

    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  Lab Setup Complete!                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Lab Targets:${NC}"
    echo -e "    DVWA ............. http://localhost:${DVWA_PORT}"
    echo -e "                       Login: ${CYAN}admin${NC} / ${CYAN}password${NC}"
    echo -e "                       Set security level via DVWA Security tab"
    echo -e ""
    echo -e "    Juice Shop ....... http://localhost:${JUICESHOP_PORT}"
    echo -e "                       Register a new account to start"
    echo -e "                       Check ${CYAN}/score-board${NC} for challenges"
    echo ""
    echo -e "  ${BOLD}Remote Access (SSH tunnel):${NC}"
    echo -e "    ${CYAN}ssh -L ${DVWA_PORT}:localhost:${DVWA_PORT} -L ${JUICESHOP_PORT}:localhost:${JUICESHOP_PORT} user@<server-ip>${NC}"
    echo ""
    echo -e "  ${BOLD}Lab Management:${NC}"
    echo -e "    ${CYAN}${INSTALL_DIR}/lab.sh status${NC}   — check what's running"
    echo -e "    ${CYAN}${INSTALL_DIR}/lab.sh start${NC}    — start the lab"
    echo -e "    ${CYAN}${INSTALL_DIR}/lab.sh stop${NC}     — stop the lab"
    echo -e "    ${CYAN}${INSTALL_DIR}/lab.sh reset${NC}    — fresh containers"
    echo -e "    ${CYAN}${INSTALL_DIR}/lab.sh destroy${NC}  — remove everything"
    echo ""
    echo -e "  ${BOLD}Installed Tools:${NC}"
    for tool in burpsuite sqlmap gobuster nikto ffuf nuclei; do
        if cmd_exists "$tool"; then
            echo -e "    ${GREEN}✓${NC} ${tool}"
        else
            echo -e "    ${YELLOW}○${NC} ${tool} (not found — install manually)"
        fi
    done
    echo ""
    echo -e "  ${BOLD}Wordlists:${NC}"
    [[ -d /usr/share/seclists ]] || [[ -d /usr/share/SecLists ]] && echo -e "    ${GREEN}✓${NC} SecLists" || echo -e "    ${YELLOW}○${NC} SecLists"
    [[ -f /usr/share/dirb/wordlists/common.txt ]] && echo -e "    ${GREEN}✓${NC} dirb wordlists" || echo -e "    ${YELLOW}○${NC} dirb wordlists"
    echo ""
    echo -e "  ${BOLD}Log file:${NC} ${LOG_FILE}"
    echo -e "  ${BOLD}Compose file:${NC} ${INSTALL_DIR}/docker-compose.yml"
    echo ""
    echo -e "  ${YELLOW}Tip:${NC} Proxy your browser through Burp Suite (127.0.0.1:8080)"
    echo -e "  ${YELLOW}Tip:${NC} Start with DVWA SQLi at 'Low' security, then progress"
    echo ""
    log "Setup completed successfully"
}

# ============================================================================
#  Uninstall function
# ============================================================================

uninstall() {
    banner
    step "Uninstalling WebApp Pentest Lab"

    warn "This will remove lab containers, images, and config files."
    warn "It will NOT remove tools (sqlmap, ffuf, nuclei, etc.)"
    echo ""
    read -rp "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled."
        exit 0
    fi

    # Stop and remove containers
    info "Stopping containers..."
    docker stop dvwa juiceshop 2>/dev/null || true
    info "Removing containers..."
    docker rm dvwa juiceshop 2>/dev/null || true
    info "Removing images..."
    docker rmi "$DVWA_IMAGE" "$JUICESHOP_IMAGE" 2>/dev/null || true

    # Remove config
    if [[ -d "$INSTALL_DIR" ]]; then
        info "Removing ${INSTALL_DIR}..."
        $SUDO rm -rf "$INSTALL_DIR"
    fi

    success "Uninstall complete"
}

# ============================================================================
#  Main
# ============================================================================

main() {
    # Handle flags
    case "${1:-}" in
        --uninstall|-u)
            uninstall
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --help, -h        Show this help message"
            echo "  --uninstall, -u   Remove lab containers and config"
            echo "  --tools-only      Install tools only (no Docker targets)"
            echo "  --targets-only    Deploy Docker targets only (skip tool install)"
            echo ""
            echo "Environment variables:"
            echo "  DVWA_PORT         Port for DVWA (default: 8080)"
            echo "  JUICESHOP_PORT    Port for Juice Shop (default: 3000)"
            exit 0
            ;;
        --tools-only)
            preflight
            pkg_update
            install_tools
            install_wordlists
            print_summary
            exit 0
            ;;
        --targets-only)
            preflight
            install_docker
            deploy_targets
            generate_compose
            generate_lab_manager
            print_summary
            exit 0
            ;;
    esac

    # Full install
    preflight
    pkg_update
    install_docker
    install_tools
    install_wordlists
    deploy_targets
    generate_compose
    generate_lab_manager
    print_summary
}

main "$@"
