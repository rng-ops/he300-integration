#!/bin/bash
# Install HE-300 stack services on Ubuntu
set -euo pipefail

echo "=== Installing HE-300 Stack ==="

# Create directories
sudo mkdir -p /opt/he300/{config,logs,data}
sudo chown -R ubuntu:ubuntu /opt/he300

# Create systemd service for HE-300 stack
cat << 'EOF' | sudo tee /etc/systemd/system/he300-stack.service
[Unit]
Description=HE-300 Benchmark Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
WorkingDirectory=/opt/he300
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

# Create health check timer
cat << 'EOF' | sudo tee /etc/systemd/system/he300-health.service
[Unit]
Description=HE-300 Health Check
After=he300-stack.service

[Service]
Type=oneshot
ExecStart=/opt/he300/health-check.sh
EOF

cat << 'EOF' | sudo tee /etc/systemd/system/he300-health.timer
[Unit]
Description=Run HE-300 health check every 5 minutes
Requires=he300-health.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=he300-health.service

[Install]
WantedBy=timers.target
EOF

# Create health check script
cat << 'HEALTH' | sudo tee /opt/he300/health-check.sh
#!/bin/bash
set -e

LOG_FILE="/opt/he300/logs/health-$(date +%Y%m%d).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== HE-300 Health Check ==="

# Check Docker
if ! docker ps &> /dev/null; then
    log "FAIL: Docker not running"
    exit 1
fi
log "OK: Docker running"

# Check services
for svc in cirisnode eee ollama postgres redis; do
    if docker ps --format '{{.Names}}' | grep -q "$svc"; then
        log "OK: $svc running"
    else
        log "WARN: $svc not found (may be using different name)"
    fi
done

# Check API endpoints
if curl -sf --max-time 5 http://localhost:8000/health > /dev/null 2>&1; then
    log "OK: CIRISNode API responding"
else
    log "WARN: CIRISNode API not responding"
fi

if curl -sf --max-time 5 http://localhost:8080/health > /dev/null 2>&1; then
    log "OK: EthicsEngine API responding"
else
    log "WARN: EthicsEngine API not responding"
fi

# Check GPU
if nvidia-smi &> /dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader)
    log "OK: GPU - $GPU_INFO"
else
    log "WARN: NVIDIA GPU not detected"
fi

log "=== Health Check Complete ==="
HEALTH

sudo chmod +x /opt/he300/health-check.sh

# Create default docker-compose.yml
cat << 'COMPOSE' | tee /opt/he300/docker-compose.yml
version: '3.8'

services:
  cirisnode:
    image: ghcr.io/rng-ops/cirisnode:latest
    container_name: cirisnode
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=postgresql://he300:${POSTGRES_PASSWORD:-changeme}@postgres:5432/he300
      - REDIS_URL=redis://:${REDIS_PASSWORD:-changeme}@redis:6379/0
      - EEE_ENABLED=true
      - EEE_BASE_URL=http://eee:8080
      - JWT_SECRET=${JWT_SECRET:-changeme}
    depends_on:
      - postgres
      - redis
      - eee
    networks:
      - he300-net
    restart: unless-stopped

  eee:
    image: ghcr.io/rng-ops/ethicsengine:latest
    container_name: eee
    ports:
      - "8080:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - DEFAULT_MODEL=${DEFAULT_MODEL:-llama3.2:3b-instruct-q4_K_M}
    depends_on:
      - ollama
    networks:
      - he300-net
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - he300-net
    restart: unless-stopped

  postgres:
    image: postgres:15-alpine
    container_name: postgres
    environment:
      - POSTGRES_USER=he300
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-changeme}
      - POSTGRES_DB=he300
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - he300-net
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: redis
    command: redis-server --requirepass ${REDIS_PASSWORD:-changeme}
    volumes:
      - redis_data:/data
    networks:
      - he300-net
    restart: unless-stopped

networks:
  he300-net:
    driver: bridge

volumes:
  ollama_data:
  postgres_data:
  redis_data:
COMPOSE

# Create default .env file
cat << 'ENV' | tee /opt/he300/.env.example
# HE-300 Environment Configuration

# Database
POSTGRES_PASSWORD=changeme

# Redis
REDIS_PASSWORD=changeme

# JWT
JWT_SECRET=changeme

# Model
DEFAULT_MODEL=llama3.2:3b-instruct-q4_K_M

# Vault (optional)
VAULT_ADDR=
VAULT_ROLE_ID=
ENV

# Enable services
sudo systemctl daemon-reload
sudo systemctl enable he300-stack.service
sudo systemctl enable he300-health.timer

echo "=== HE-300 Stack installation complete ==="
echo "Start with: sudo systemctl start he300-stack"
echo "Or: cd /opt/he300 && docker compose up -d"
