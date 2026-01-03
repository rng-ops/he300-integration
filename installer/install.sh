#!/bin/bash
#===============================================================================
#
#  HE-300 Benchmark Suite Installer
#  
#  Installs and configures the complete HE-300 ethical benchmark stack:
#  - CIRISNode with EthicsEngine Enterprise integration
#  - GPU-accelerated inference (NVIDIA A10 24GB)
#  - HashiCorp Vault for secrets management
#  - WireGuard VPN for secure communication
#  - Results Dashboard
#
#  Supported Platforms:
#  - Lambda Stack 22.04/24.04
#  - GPU Base Ubuntu 24.04
#  - Ubuntu 22.04/24.04
#
#  Usage: ./install.sh [OPTIONS]
#
#  Options:
#    --minimal       Install core components only (no dashboard)
#    --no-vault      Skip Vault installation (use env vars for secrets)
#    --no-wireguard  Skip WireGuard VPN setup
#    --dev           Development mode (use local images)
#    --help          Show this help message
#
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="${INSTALL_DIR:-/opt/he300}"
DATA_DIR="${DATA_DIR:-/var/lib/he300}"
LOG_DIR="${LOG_DIR:-/var/log/he300}"
CONFIG_DIR="${CONFIG_DIR:-/etc/he300}"

# Versions
DOCKER_COMPOSE_VERSION="2.24.0"
VAULT_VERSION="1.15.4"

# Options
MINIMAL=false
NO_VAULT=false
NO_WIREGUARD=false
DEV_MODE=false

#===============================================================================
# Utility Functions
#===============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}  $1${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root. Use: sudo ./install.sh"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    # Check for Lambda Stack
    if command -v lambda-stack-upgrade &> /dev/null || dpkg -l | grep -q lambda-stack; then
        LAMBDA_STACK=true
        log_info "Detected Lambda Stack installation"
    else
        LAMBDA_STACK=false
    fi

    log_info "Detected OS: $OS $VERSION (Lambda Stack: $LAMBDA_STACK)"
}

check_gpu() {
    log_step "Checking GPU Configuration"

    if ! command -v nvidia-smi &> /dev/null; then
        log_warn "nvidia-smi not found. GPU support may not be configured."
        GPU_AVAILABLE=false
        return
    fi

    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true)
    
    if [ -z "$GPU_INFO" ]; then
        log_warn "No NVIDIA GPU detected"
        GPU_AVAILABLE=false
        return
    fi

    GPU_AVAILABLE=true
    log_success "GPU detected: $GPU_INFO"

    # Check for A10
    if echo "$GPU_INFO" | grep -qi "A10"; then
        log_success "NVIDIA A10 detected - optimal for HE-300 benchmark"
    fi

    # Check CUDA
    if [ -f /usr/local/cuda/version.txt ]; then
        CUDA_VERSION=$(cat /usr/local/cuda/version.txt)
        log_info "CUDA version: $CUDA_VERSION"
    elif command -v nvcc &> /dev/null; then
        CUDA_VERSION=$(nvcc --version | grep release | awk '{print $6}')
        log_info "CUDA version: $CUDA_VERSION"
    fi
}

check_memory() {
    TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
    log_info "Total system memory: ${TOTAL_MEM}GB"

    if [ "$TOTAL_MEM" -lt 32 ]; then
        log_warn "Recommended minimum memory is 32GB for optimal performance"
    fi
}

check_disk() {
    AVAILABLE_DISK=$(df -BG "${INSTALL_DIR%/*}" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
    log_info "Available disk space: ${AVAILABLE_DISK}GB"

    if [ "${AVAILABLE_DISK:-0}" -lt 100 ]; then
        log_warn "Recommended minimum disk space is 100GB"
    fi
}

#===============================================================================
# Installation Functions
#===============================================================================

install_dependencies() {
    log_step "Installing System Dependencies"

    apt-get update -qq

    PACKAGES=(
        apt-transport-https
        ca-certificates
        curl
        gnupg
        lsb-release
        jq
        git
        unzip
        htop
        tmux
        python3
        python3-pip
        python3-venv
    )

    apt-get install -y "${PACKAGES[@]}"
    log_success "System dependencies installed"
}

install_docker() {
    log_step "Installing Docker"

    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        log_info "Docker already installed: $DOCKER_VERSION"
    else
        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Add the repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        log_success "Docker installed"
    fi

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Add current user to docker group
    if [ -n "${SUDO_USER:-}" ]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group"
    fi
}

install_nvidia_container_toolkit() {
    log_step "Installing NVIDIA Container Toolkit"

    if ! $GPU_AVAILABLE; then
        log_warn "No GPU detected, skipping NVIDIA Container Toolkit"
        return
    fi

    if dpkg -l | grep -q nvidia-container-toolkit; then
        log_info "NVIDIA Container Toolkit already installed"
        return
    fi

    # Add NVIDIA Container Toolkit repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit

    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    log_success "NVIDIA Container Toolkit installed and configured"
}

install_vault() {
    log_step "Installing HashiCorp Vault"

    if $NO_VAULT; then
        log_info "Skipping Vault installation (--no-vault specified)"
        return
    fi

    if command -v vault &> /dev/null; then
        VAULT_VER=$(vault --version)
        log_info "Vault already installed: $VAULT_VER"
        return
    fi

    # Add HashiCorp GPG key
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

    # Add HashiCorp repository
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/hashicorp.list

    apt-get update -qq
    apt-get install -y vault

    log_success "Vault installed"
}

install_wireguard() {
    log_step "Installing WireGuard"

    if $NO_WIREGUARD; then
        log_info "Skipping WireGuard installation (--no-wireguard specified)"
        return
    fi

    if command -v wg &> /dev/null; then
        log_info "WireGuard already installed"
        return
    fi

    apt-get install -y wireguard wireguard-tools

    log_success "WireGuard installed"
}

#===============================================================================
# Configuration Functions
#===============================================================================

create_directories() {
    log_step "Creating Directory Structure"

    mkdir -p "$INSTALL_DIR"/{bin,config,scripts}
    mkdir -p "$DATA_DIR"/{models,results,artifacts}
    mkdir -p "$LOG_DIR"
    mkdir -p "$CONFIG_DIR"

    log_success "Directories created"
}

clone_repositories() {
    log_step "Cloning Repositories"

    cd "$INSTALL_DIR"

    # Clone or update CIRISNode
    if [ -d "CIRISNode" ]; then
        log_info "Updating CIRISNode..."
        cd CIRISNode && git pull && cd ..
    else
        log_info "Cloning CIRISNode..."
        git clone https://github.com/rng-ops/CIRISNode.git --branch feature/eee-integration
    fi

    # Clone or update EthicsEngine Enterprise
    if [ -d "ethicsengine_enterprise" ]; then
        log_info "Updating EthicsEngine Enterprise..."
        cd ethicsengine_enterprise && git pull && cd ..
    else
        log_info "Cloning EthicsEngine Enterprise..."
        git clone https://github.com/rng-ops/ethicsengine_enterprise.git --branch feature/he300-api
    fi

    log_success "Repositories cloned"
}

generate_secrets() {
    log_step "Generating Secrets"

    SECRETS_FILE="$CONFIG_DIR/secrets.env"

    if [ -f "$SECRETS_FILE" ]; then
        log_warn "Secrets file already exists at $SECRETS_FILE"
        read -p "Regenerate secrets? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    # Generate secrets
    JWT_SECRET=$(openssl rand -base64 32)
    DB_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/')
    REDIS_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/')
    WEBHOOK_SECRET=$(openssl rand -hex 32)
    SIGNING_KEY=$(openssl rand -hex 32)

    cat > "$SECRETS_FILE" << EOF
# HE-300 Secrets - Generated $(date -Iseconds)
# DO NOT COMMIT THIS FILE TO VERSION CONTROL

# Database
POSTGRES_PASSWORD=$DB_PASSWORD
DB_PASSWORD=$DB_PASSWORD

# Redis
REDIS_PASSWORD=$REDIS_PASSWORD

# JWT Authentication
JWT_SECRET=$JWT_SECRET

# Webhook Authentication
WEBHOOK_SECRET=$WEBHOOK_SECRET

# Ed25519 Signing Key (hex)
SIGNING_KEY=$SIGNING_KEY

# API Keys (configure as needed)
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
# HUGGINGFACE_TOKEN=
EOF

    chmod 600 "$SECRETS_FILE"
    log_success "Secrets generated and saved to $SECRETS_FILE"
}

configure_environment() {
    log_step "Configuring Environment"

    ENV_FILE="$CONFIG_DIR/environment.env"

    cat > "$ENV_FILE" << EOF
# HE-300 Environment Configuration

# Paths
INSTALL_DIR=$INSTALL_DIR
DATA_DIR=$DATA_DIR
LOG_DIR=$LOG_DIR
CONFIG_DIR=$CONFIG_DIR

# Model Configuration
MODEL_CACHE_DIR=$DATA_DIR/models
DEFAULT_MODEL=Qwen/Qwen2.5-7B-Instruct
DEFAULT_QUANTIZATION=Q4_K_M

# GPU Configuration
CUDA_VISIBLE_DEVICES=0
GPU_MEMORY_FRACTION=0.9

# Service Ports
CIRISNODE_PORT=8000
EEE_PORT=8080
DASHBOARD_PORT=3000
VAULT_PORT=8200

# Logging
LOG_LEVEL=INFO
EOF

    chmod 644 "$ENV_FILE"
    log_success "Environment configured"
}

create_systemd_services() {
    log_step "Creating Systemd Services"

    # CIRISNode service
    cat > /etc/systemd/system/he300-cirisnode.service << EOF
[Unit]
Description=HE-300 CIRISNode Service
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_DIR/environment.env
EnvironmentFile=$CONFIG_DIR/secrets.env
ExecStartPre=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml pull
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml up
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker-compose.yml down
TimeoutStartSec=300
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

    # Dashboard service (optional)
    if ! $MINIMAL; then
        cat > /etc/systemd/system/he300-dashboard.service << EOF
[Unit]
Description=HE-300 Dashboard Service
After=docker.service he300-cirisnode.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_DIR/environment.env
EnvironmentFile=$CONFIG_DIR/secrets.env
ExecStart=/usr/bin/docker compose -f $INSTALL_DIR/docker/docker-compose.dashboard.yml up
ExecStop=/usr/bin/docker compose -f $INSTALL_DIR/docker/docker-compose.dashboard.yml down
TimeoutStartSec=300
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    log_success "Systemd services created"
}

#===============================================================================
# Docker Compose Configuration
#===============================================================================

create_docker_compose() {
    log_step "Creating Docker Compose Configuration"

    cat > "$INSTALL_DIR/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  cirisnode:
    build:
      context: ./CIRISNode
      dockerfile: Dockerfile
    ports:
      - "${CIRISNODE_PORT:-8000}:8000"
    environment:
      DATABASE_URL: postgresql://ciris:${DB_PASSWORD}@db:5432/cirisnode
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      JWT_SECRET: ${JWT_SECRET}
      EEE_BASE_URL: http://ethicsengine:8080
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ${DATA_DIR}/results:/app/results
      - ${LOG_DIR}/cirisnode:/app/logs
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - he300-internal
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  ethicsengine:
    build:
      context: ./ethicsengine_enterprise
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: postgresql://eee:${DB_PASSWORD}@db:5432/ethicsengine
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      MODEL_CACHE_DIR: /models
      DEFAULT_MODEL: ${DEFAULT_MODEL:-Qwen/Qwen2.5-7B-Instruct}
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
    volumes:
      - ${DATA_DIR}/models:/models
      - ${LOG_DIR}/eee:/app/logs
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - he300-internal
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sql:/docker-entrypoint-initdb.d/init.sql
    networks:
      - he300-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    networks:
      - he300-internal
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  celery-worker:
    build:
      context: ./CIRISNode
      dockerfile: Dockerfile
    command: celery -A cirisnode.celery_app worker -l info -c 2
    environment:
      DATABASE_URL: postgresql://ciris:${DB_PASSWORD}@db:5432/cirisnode
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      EEE_BASE_URL: http://ethicsengine:8080
    depends_on:
      - db
      - redis
      - ethicsengine
    volumes:
      - ${DATA_DIR}/results:/app/results
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - he300-internal
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:

networks:
  he300-internal:
    driver: bridge
EOF

    # Create init-db.sql
    cat > "$INSTALL_DIR/init-db.sql" << 'EOF'
-- Initialize HE-300 Databases

-- Create databases
CREATE DATABASE cirisnode;
CREATE DATABASE ethicsengine;
CREATE DATABASE he300_dashboard;

-- Create users
CREATE USER ciris WITH PASSWORD 'PLACEHOLDER';
CREATE USER eee WITH PASSWORD 'PLACEHOLDER';
CREATE USER dashboard WITH PASSWORD 'PLACEHOLDER';

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE cirisnode TO ciris;
GRANT ALL PRIVILEGES ON DATABASE ethicsengine TO eee;
GRANT ALL PRIVILEGES ON DATABASE he300_dashboard TO dashboard;

-- Enable extensions
\c cirisnode
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

\c ethicsengine
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

\c he300_dashboard
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
EOF

    log_success "Docker Compose configuration created"
}

#===============================================================================
# Utility Scripts
#===============================================================================

create_utility_scripts() {
    log_step "Creating Utility Scripts"

    # Start script
    cat > "$INSTALL_DIR/bin/he300-start" << 'EOF'
#!/bin/bash
set -e
cd /opt/he300
source /etc/he300/environment.env
source /etc/he300/secrets.env
docker compose up -d
echo "HE-300 services started"
docker compose ps
EOF

    # Stop script
    cat > "$INSTALL_DIR/bin/he300-stop" << 'EOF'
#!/bin/bash
set -e
cd /opt/he300
docker compose down
echo "HE-300 services stopped"
EOF

    # Status script
    cat > "$INSTALL_DIR/bin/he300-status" << 'EOF'
#!/bin/bash
cd /opt/he300
echo "=== HE-300 Service Status ==="
docker compose ps
echo ""
echo "=== GPU Status ==="
nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv
EOF

    # Run benchmark script
    cat > "$INSTALL_DIR/bin/he300-benchmark" << 'EOF'
#!/bin/bash
set -e

MODEL="${1:-Qwen/Qwen2.5-7B-Instruct}"
SAMPLE_SIZE="${2:-300}"
CATEGORIES="${3:-commonsense,deontology,justice,utilitarianism,virtue}"

echo "Starting HE-300 benchmark..."
echo "  Model: $MODEL"
echo "  Sample Size: $SAMPLE_SIZE"
echo "  Categories: $CATEGORIES"
echo ""

curl -X POST http://localhost:8000/api/benchmarks/run \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"sample_size\": $SAMPLE_SIZE,
    \"categories\": \"$CATEGORIES\"
  }"
EOF

    # Logs script
    cat > "$INSTALL_DIR/bin/he300-logs" << 'EOF'
#!/bin/bash
SERVICE="${1:-cirisnode}"
cd /opt/he300
docker compose logs -f "$SERVICE"
EOF

    # Make scripts executable
    chmod +x "$INSTALL_DIR/bin/"*

    # Add to PATH
    if ! grep -q "/opt/he300/bin" /etc/profile.d/he300.sh 2>/dev/null; then
        echo 'export PATH="/opt/he300/bin:$PATH"' > /etc/profile.d/he300.sh
    fi

    log_success "Utility scripts created"
}

#===============================================================================
# Main Installation
#===============================================================================

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    
  ██╗  ██╗███████╗      ██████╗  ██████╗  ██████╗ 
  ██║  ██║██╔════╝      ╚════██╗██╔═████╗██╔═████╗
  ███████║█████╗   █████╗ █████╔╝██║██╔██║██║██╔██║
  ██╔══██║██╔══╝   ╚════╝ ╚═══██╗████╔╝██║████╔╝██║
  ██║  ██║███████╗      ██████╔╝╚██████╔╝╚██████╔╝
  ╚═╝  ╚═╝╚══════╝      ╚═════╝  ╚═════╝  ╚═════╝ 
                                                   
  Ethical Benchmark Suite Installer
  CIRISNode + EthicsEngine Enterprise

EOF
    echo -e "${NC}"
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --minimal       Install core components only (no dashboard)
    --no-vault      Skip Vault installation (use env vars for secrets)
    --no-wireguard  Skip WireGuard VPN setup
    --dev           Development mode (use local images)
    --help          Show this help message

Examples:
    sudo ./install.sh                    # Full installation
    sudo ./install.sh --minimal          # Core components only
    sudo ./install.sh --no-vault --dev   # Dev mode without Vault

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --minimal)
                MINIMAL=true
                shift
                ;;
            --no-vault)
                NO_VAULT=true
                shift
                ;;
            --no-wireguard)
                NO_WIREGUARD=true
                shift
                ;;
            --dev)
                DEV_MODE=true
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    
    print_banner
    check_root
    
    log_step "Pre-Installation Checks"
    detect_os
    check_gpu
    check_memory
    check_disk

    # Confirm installation
    echo ""
    log_info "Installation Configuration:"
    log_info "  Install Directory: $INSTALL_DIR"
    log_info "  Data Directory: $DATA_DIR"
    log_info "  Minimal Mode: $MINIMAL"
    log_info "  Vault: $([ $NO_VAULT = true ] && echo 'Disabled' || echo 'Enabled')"
    log_info "  WireGuard: $([ $NO_WIREGUARD = true ] && echo 'Disabled' || echo 'Enabled')"
    log_info "  GPU Available: $GPU_AVAILABLE"
    echo ""

    read -p "Proceed with installation? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi

    # Run installation steps
    install_dependencies
    install_docker
    install_nvidia_container_toolkit
    install_vault
    install_wireguard
    
    create_directories
    clone_repositories
    generate_secrets
    configure_environment
    create_docker_compose
    create_systemd_services
    create_utility_scripts

    # Final summary
    log_step "Installation Complete!"

    echo -e "${GREEN}"
    cat << EOF

  ✅ HE-300 Benchmark Suite has been installed!

  Quick Start:
  ─────────────────────────────────────────────
  1. Review and configure secrets:
     sudo nano $CONFIG_DIR/secrets.env

  2. Start services:
     sudo he300-start
     # or: sudo systemctl start he300-cirisnode

  3. Check status:
     he300-status

  4. Run benchmark:
     he300-benchmark "Qwen/Qwen2.5-7B-Instruct" 300

  5. View logs:
     he300-logs cirisnode
     he300-logs ethicsengine

  Endpoints:
  ─────────────────────────────────────────────
  CIRISNode API:    http://localhost:8000
  EthicsEngine:     http://localhost:8080
  Dashboard:        http://localhost:3000 (if installed)

  Documentation:
  ─────────────────────────────────────────────
  $INSTALL_DIR/docs/RUN.md
  $INSTALL_DIR/docs/QUICKSTART.md

EOF
    echo -e "${NC}"
}

main "$@"
