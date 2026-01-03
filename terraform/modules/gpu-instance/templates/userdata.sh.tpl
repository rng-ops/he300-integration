#!/bin/bash
# HE-300 GPU Host Initialization Script
# This script runs on first boot via cloud-init

set -euo pipefail

exec > >(tee /var/log/he300-init.log) 2>&1

echo "=== HE-300 GPU Host Initialization ==="
echo "Environment: ${environment}"
echo "GPU Type: ${gpu_type}"
echo "Started at: $(date)"

# Variables from Terraform template
ENVIRONMENT="${environment}"
VAULT_ADDR="${vault_addr}"
VAULT_ROLE_ID="${vault_role_id}"
INSTALL_NVIDIA="${install_nvidia}"
GPU_TYPE="${gpu_type}"
DEFAULT_MODEL="${default_model}"
QUANTIZATION="${quantization}"
DOCKER_COMPOSE_URL="${docker_compose_url}"

# Update system
apt-get update
apt-get upgrade -y

# Install essential packages
apt-get install -y \
    curl \
    wget \
    git \
    jq \
    unzip \
    htop \
    nvtop \
    wireguard \
    net-tools

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
fi

# Start Docker
systemctl enable docker
systemctl start docker

# Install Docker Compose plugin
if ! docker compose version &> /dev/null; then
    echo "Installing Docker Compose..."
    apt-get install -y docker-compose-plugin
fi

# Install NVIDIA drivers if needed
if [ "$INSTALL_NVIDIA" = "true" ]; then
    echo "Installing NVIDIA drivers..."
    apt-get install -y nvidia-driver-535 nvidia-utils-535
    
    # Install NVIDIA Container Toolkit
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

# Install Vault CLI
echo "Installing Vault CLI..."
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/hashicorp.list
apt-get update
apt-get install -y vault

# Create HE-300 directory
mkdir -p /opt/he300
cd /opt/he300

# Fetch secrets from Vault if configured
if [ -n "$VAULT_ADDR" ] && [ -n "$VAULT_ROLE_ID" ]; then
    echo "Fetching secrets from Vault..."
    export VAULT_ADDR
    
    # Get secret ID from instance metadata or generate
    # In production, secret_id would come from secure bootstrap
    # For now, we'll use the role_id to authenticate
    
    # This is a placeholder - in production, use proper AppRole authentication
    echo "Vault integration configured for: $VAULT_ADDR"
fi

# Download Docker Compose file
echo "Downloading Docker Compose configuration..."
curl -fsSL "$DOCKER_COMPOSE_URL" -o docker-compose.yml

# Create environment file
cat > .env << EOF
# HE-300 Environment Configuration
ENVIRONMENT=$ENVIRONMENT
GPU_TYPE=$GPU_TYPE

# Service ports
CIRISNODE_PORT=8000
EEE_PORT=8080
OLLAMA_PORT=11434

# Model configuration
DEFAULT_MODEL=$DEFAULT_MODEL
QUANTIZATION=$QUANTIZATION

# Vault configuration
VAULT_ADDR=$VAULT_ADDR

# Generated secrets (will be populated from Vault or generated)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
REDIS_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -base64 48)
CIRISNODE_API_KEY=$(openssl rand -hex 32)
EOF

chmod 600 .env

# Pull Docker images
echo "Pulling Docker images..."
docker compose pull

# Start services
echo "Starting HE-300 stack..."
docker compose up -d

# Wait for Ollama to be ready
echo "Waiting for Ollama to start..."
sleep 10

# Pull the default model
echo "Pulling model: $DEFAULT_MODEL..."
docker exec ollama ollama pull "$DEFAULT_MODEL" || true

# Create systemd service for auto-start
cat > /etc/systemd/system/he300-stack.service << 'SYSTEMD'
[Unit]
Description=HE-300 Benchmark Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/he300
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable he300-stack.service

# Create health check script
cat > /opt/he300/health-check.sh << 'HEALTH'
#!/bin/bash
set -e

echo "=== HE-300 Health Check ==="

# Check Docker
if ! docker ps &> /dev/null; then
    echo "FAIL: Docker not running"
    exit 1
fi
echo "OK: Docker running"

# Check services
for svc in cirisnode eee ollama postgres redis; do
    if docker ps --format '{{.Names}}' | grep -q "$svc"; then
        echo "OK: $svc running"
    else
        echo "FAIL: $svc not running"
        exit 1
    fi
done

# Check API endpoints
if curl -sf http://localhost:8000/health > /dev/null; then
    echo "OK: CIRISNode API responding"
else
    echo "FAIL: CIRISNode API not responding"
    exit 1
fi

if curl -sf http://localhost:8080/health > /dev/null; then
    echo "OK: EthicsEngine API responding"
else
    echo "FAIL: EthicsEngine API not responding"
    exit 1
fi

# Check GPU
if nvidia-smi &> /dev/null; then
    echo "OK: NVIDIA GPU detected"
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv
else
    echo "WARN: NVIDIA GPU not detected"
fi

echo "=== Health Check Complete ==="
HEALTH

chmod +x /opt/he300/health-check.sh

# Setup cron for periodic health checks
echo "*/5 * * * * root /opt/he300/health-check.sh >> /var/log/he300-health.log 2>&1" > /etc/cron.d/he300-health

echo ""
echo "=== HE-300 GPU Host Initialization Complete ==="
echo "Completed at: $(date)"
echo ""
echo "Services:"
echo "  CIRISNode: http://$(hostname -I | awk '{print $1}'):8000"
echo "  EthicsEngine: http://$(hostname -I | awk '{print $1}'):8080"
echo "  Ollama: http://$(hostname -I | awk '{print $1}'):11434"
echo ""
echo "Run health check: /opt/he300/health-check.sh"
