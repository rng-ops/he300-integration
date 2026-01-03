# HE-300 Distributed Runner Architecture

## Overview

This document describes the architecture for deploying and running HE-300 benchmarks across distributed infrastructure, where:

- **GPU Host** (Lambda Labs A10, local Mac, etc.) runs the inference server and CIRISNode sidecar
- **Test Runner** (GitHub Actions, local dev, CI server) orchestrates benchmarks and collects results

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              TEST RUNNER                                     │
│  (GitHub Actions / Local Dev / Jenkins / GitLab CI)                         │
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │  Benchmark      │    │  Results        │    │  Report         │         │
│  │  Orchestrator   │───▶│  Collector      │───▶│  Generator      │         │
│  └────────┬────────┘    └─────────────────┘    └─────────────────┘         │
│           │                                                                 │
└───────────┼─────────────────────────────────────────────────────────────────┘
            │
            │ HTTPS / WireGuard VPN
            │ Port 8000 (CIRISNode)
            │ Port 8080 (EthicsEngine)
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GPU HOST                                        │
│  Lambda A10 / Mac M-series / Custom GPU Server                              │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     Docker Network: he300-net                        │   │
│  │                                                                      │   │
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────┐ │   │
│  │  │  CIRISNode  │──▶│  Ethics     │──▶│   Ollama    │──▶│  GPU    │ │   │
│  │  │  :8000      │   │  Engine     │   │   :11434    │   │  A10    │ │   │
│  │  │  (Sidecar)  │   │  :8080      │   │             │   │  24GB   │ │   │
│  │  └─────────────┘   └─────────────┘   └─────────────┘   └─────────┘ │   │
│  │        │                 │                                          │   │
│  │        ▼                 ▼                                          │   │
│  │  ┌─────────────┐   ┌─────────────┐                                  │   │
│  │  │   Redis     │   │  PostgreSQL │                                  │   │
│  │  │   :6379     │   │   :5432     │                                  │   │
│  │  └─────────────┘   └─────────────┘                                  │   │
│  │                                                                      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────┐                                                        │
│  │   WireGuard     │◀── Tunnel to Test Runner (optional)                   │
│  │   wg0: 10.0.0.x │                                                        │
│  └─────────────────┘                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Deployment Modes

### Mode 1: Local Development

```
┌─────────────────────────────────────────┐
│          Developer Machine              │
│                                         │
│  pytest ──▶ CIRISNode ──▶ EEE ──▶ LLM  │
│  (local)    (docker)     (docker) (local)│
│                                         │
│  All on localhost, no VPN needed        │
└─────────────────────────────────────────┘
```

**Use case**: Developer testing on local machine with GPU (Mac M-series, Linux + NVIDIA)

**Connection**: `localhost:8000` → `localhost:8080` → `localhost:11434`

---

### Mode 2: Remote GPU (Direct HTTPS)

```
┌────────────────┐         HTTPS          ┌────────────────┐
│  Test Runner   │ ──────────────────────▶│   GPU Host     │
│  (GitHub/CI)   │     (Public IP)        │  (Lambda A10)  │
│                │                         │                │
│  Port 443 ─────┼─────────────────────── │──▶ :8000       │
└────────────────┘                         └────────────────┘
```

**Use case**: CI runner connecting to cloud GPU with public IP

**Connection**: Test runner → `https://gpu-host.example.com:8000`

**Security**: 
- HTTPS with Let's Encrypt certificate
- API key authentication
- IP allowlist (GitHub Actions IP ranges)

---

### Mode 3: Remote GPU (WireGuard VPN)

```
┌────────────────┐                         ┌────────────────┐
│  Test Runner   │                         │   GPU Host     │
│  wg0: 10.0.0.1 │ ══════════════════════ │  wg0: 10.0.0.2 │
│                │     WireGuard VPN       │                │
│  10.0.0.2:8000 │◀────────────────────── │  :8000         │
└────────────────┘                         └────────────────┘
```

**Use case**: Private GPU host behind NAT, GitHub Actions with self-hosted runner

**Connection**: Test runner → `10.0.0.2:8000` (via WireGuard tunnel)

**Security**:
- WireGuard encryption
- No public IP exposure
- Mutual authentication via public keys

---

## Installer Package

### Package Contents

```
he300-installer/
├── install.sh                    # Main installer script
├── uninstall.sh                  # Removal script
├── config/
│   ├── install.yaml              # Installation configuration
│   ├── models.yaml               # Model weight configurations
│   └── wireguard/
│       ├── wg0.conf.template     # WireGuard config template
│       └── generate-keys.sh      # Key generation script
├── docker/
│   ├── docker-compose.gpu.yml    # GPU host compose file
│   ├── docker-compose.cpu.yml    # CPU-only fallback
│   └── .env.template             # Environment template
├── systemd/
│   ├── he300-stack.service       # Systemd service unit
│   └── he300-health.timer        # Health check timer
├── scripts/
│   ├── setup-nvidia.sh           # NVIDIA driver setup
│   ├── setup-ollama.sh           # Ollama installation
│   ├── pull-models.sh            # Model weight download
│   ├── health-check.sh           # Stack health verification
│   └── benchmark-test.sh         # Quick validation benchmark
└── docs/
    └── INSTALL.md                # Installation guide
```

### Installation Configuration (`install.yaml`)

```yaml
# Target host configuration
target:
  host: "gpu-server.example.com"
  user: "ubuntu"
  ssh_key: "~/.ssh/id_ed25519"
  port: 22

# OS detection (auto or manual)
os:
  detect: auto
  # manual: "ubuntu-22.04" | "ubuntu-24.04" | "lambda-22.04" | "lambda-24.04"

# GPU configuration
gpu:
  type: auto  # auto-detect, or: a10, a100, rtx4090, m1, m2, m3
  memory: auto
  nvidia_driver: auto  # or specific version: "535.104.05"

# Model configuration
models:
  default: "llama-3.2-3B-instruct"
  pull_on_install:
    - "llama-3.2-3B-instruct"
  quantization: "Q4_K_M"  # Q4_K_M, Q5_K_M, Q8_0, fp16

# Network configuration
network:
  mode: "direct"  # direct, wireguard, tailscale
  
  direct:
    https: true
    certbot: true
    domain: "gpu-server.example.com"
  
  wireguard:
    enabled: false
    interface: "wg0"
    listen_port: 51820
    address: "10.0.0.2/24"
    peer_public_key: ""  # Test runner's public key
    peer_endpoint: ""    # Test runner's public IP:port
    peer_allowed_ips: "10.0.0.1/32"
  
  tailscale:
    enabled: false
    auth_key: ""  # Tailscale auth key

# Service configuration
services:
  cirisnode:
    port: 8000
    replicas: 1
  
  ethicsengine:
    port: 8080
    replicas: 1
  
  ollama:
    port: 11434
    gpu_layers: -1  # All layers on GPU
  
  redis:
    port: 6379
    persistence: true
  
  postgres:
    port: 5432
    persistence: true

# Security
security:
  api_key: ""  # Generated if empty
  jwt_secret: ""  # Generated if empty
  allowed_ips: []  # Empty = allow all, or list of CIDRs
```

### Model Weight Configuration (`models.yaml`)

```yaml
# Model registry
models:
  # Llama 3.2 variants
  llama-3.2-3B-instruct:
    ollama_name: "llama3.2:3b-instruct-q4_K_M"
    context_length: 8192
    recommended_gpu_memory: 4  # GB
    quantizations:
      Q4_K_M: "llama3.2:3b-instruct-q4_K_M"
      Q5_K_M: "llama3.2:3b-instruct-q5_K_M"
      Q8_0: "llama3.2:3b-instruct-q8_0"
      fp16: "llama3.2:3b-instruct-fp16"
  
  llama-3.2-8B-instruct:
    ollama_name: "llama3.2:8b-instruct-q4_K_M"
    context_length: 8192
    recommended_gpu_memory: 8
    quantizations:
      Q4_K_M: "llama3.2:8b-instruct-q4_K_M"
      Q5_K_M: "llama3.2:8b-instruct-q5_K_M"
      Q8_0: "llama3.2:8b-instruct-q8_0"
      fp16: "llama3.2:8b-instruct-fp16"
  
  # Mistral variants
  mistral-7B-instruct:
    ollama_name: "mistral:7b-instruct-q4_K_M"
    context_length: 8192
    recommended_gpu_memory: 8
    quantizations:
      Q4_K_M: "mistral:7b-instruct-q4_K_M"
      Q5_K_M: "mistral:7b-instruct-q5_K_M"
      Q8_0: "mistral:7b-instruct-q8_0"

# A10 24GB optimized configurations
gpu_profiles:
  a10-24gb:
    max_model_size: "13B"
    recommended_models:
      - "llama-3.2-8B-instruct"
      - "mistral-7B-instruct"
    max_batch_size: 50
    concurrent_requests: 4
    
  a100-40gb:
    max_model_size: "70B"
    recommended_models:
      - "llama-3.2-70B-instruct"
    max_batch_size: 100
    concurrent_requests: 8

  mac-m1-16gb:
    max_model_size: "7B"
    recommended_models:
      - "llama-3.2-3B-instruct"
    max_batch_size: 20
    concurrent_requests: 2
```

---

## Installation Flow

### Phase 1: Remote Setup

```bash
# From local machine / CI runner
./install.sh --config install.yaml

# What happens:
# 1. SSH to target host
# 2. Detect OS and GPU
# 3. Install Docker if needed
# 4. Install NVIDIA Container Toolkit (if NVIDIA GPU)
# 5. Pull Docker images
# 6. Configure services
# 7. Set up networking (direct/WireGuard/Tailscale)
# 8. Start stack
# 9. Pull model weights
# 10. Run health check
# 11. Run quick benchmark validation
```

### Phase 2: OS-Specific Setup

```
┌─────────────────────────────────────────────────────────────────┐
│                    OS Detection & Setup                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Lambda Stack 22.04 / 24.04                                     │
│  ├── Docker: pre-installed                                      │
│  ├── NVIDIA: pre-installed (Lambda drivers)                    │
│  ├── CUDA: pre-installed                                        │
│  └── Action: Install NVIDIA Container Toolkit only              │
│                                                                  │
│  Ubuntu 22.04 / 24.04                                           │
│  ├── Docker: apt install docker.io                              │
│  ├── NVIDIA: Install from nvidia-driver-535                    │
│  ├── CUDA: Install nvidia-container-toolkit                    │
│  └── Action: Full driver + toolkit installation                 │
│                                                                  │
│  GPU Base 24.04                                                  │
│  ├── Docker: pre-installed                                      │
│  ├── NVIDIA: pre-installed                                      │
│  └── Action: Minimal setup, verify only                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 3: Network Configuration

#### Direct HTTPS (Public IP)

```bash
# Auto-configure with certbot
./install.sh --network direct --domain gpu.example.com

# Firewall rules
ufw allow 8000/tcp  # CIRISNode
ufw allow 8080/tcp  # EthicsEngine
ufw allow 443/tcp   # HTTPS proxy
```

#### WireGuard VPN

```bash
# On GPU host (generates keys)
./install.sh --network wireguard --wg-address 10.0.0.2/24

# Output: GPU host public key
# WG_PUBLIC_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# On test runner (GitHub self-hosted runner)
./scripts/setup-wireguard-client.sh \
  --address 10.0.0.1/24 \
  --peer-key "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  --peer-endpoint "gpu-host-ip:51820"
```

#### Tailscale (Simplest)

```bash
# On GPU host
./install.sh --network tailscale --ts-authkey "tskey-xxx"

# On test runner
tailscale up --authkey "tskey-xxx"
# Access via: gpu-host.ts.net:8000
```

---

## Test Runner Configuration

### GitHub Actions (Remote GPU)

```yaml
# .github/workflows/he300-benchmark.yml
name: HE-300 Benchmark

on:
  workflow_dispatch:
    inputs:
      gpu_host:
        description: 'GPU host address'
        default: '10.0.0.2'  # WireGuard address
      model:
        description: 'Model to test'
        default: 'llama-3.2-3B-instruct'

jobs:
  benchmark:
    runs-on: ubuntu-latest  # or self-hosted with WireGuard
    
    steps:
      - uses: actions/checkout@v4
      
      # Option A: Direct HTTPS connection
      - name: Run benchmark (HTTPS)
        if: ${{ !inputs.use_wireguard }}
        env:
          CIRISNODE_URL: https://${{ inputs.gpu_host }}:8000
          API_KEY: ${{ secrets.CIRISNODE_API_KEY }}
        run: ./scripts/run_he300_benchmark.sh
      
      # Option B: WireGuard tunnel
      - name: Setup WireGuard
        if: ${{ inputs.use_wireguard }}
        run: |
          sudo apt-get install -y wireguard
          echo "${{ secrets.WG_PRIVATE_KEY }}" | sudo tee /etc/wireguard/wg0.conf
          sudo wg-quick up wg0
      
      - name: Run benchmark (WireGuard)
        if: ${{ inputs.use_wireguard }}
        env:
          CIRISNODE_URL: http://10.0.0.2:8000
        run: ./scripts/run_he300_benchmark.sh
```

### GitHub Actions (Self-Hosted GPU Runner)

```yaml
# GPU host IS the runner - no network complexity
jobs:
  benchmark:
    runs-on: self-hosted  # Label for GPU machine
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Start stack
        run: docker compose -f docker/docker-compose.gpu.yml up -d
      
      - name: Run benchmark
        env:
          CIRISNODE_URL: http://localhost:8000
        run: ./scripts/run_he300_benchmark.sh
```

### Local Development

```bash
# Start local stack
make dev-up

# Run benchmark against local stack
export CIRISNODE_URL=http://localhost:8000
./scripts/run_he300_benchmark.sh --model ollama/llama3.2 --sample-size 50
```

---

## Network Security

### API Authentication

```
┌─────────────────────────────────────────────────────────────────┐
│                    Authentication Flow                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Test Runner                        GPU Host                     │
│       │                                  │                       │
│       │─── POST /auth/login ────────────▶│                       │
│       │    {api_key: "xxx"}              │                       │
│       │                                  │                       │
│       │◀── {token: "jwt.xxx"} ──────────│                       │
│       │                                  │                       │
│       │─── GET /he300/batch ────────────▶│                       │
│       │    Authorization: Bearer jwt.xxx │                       │
│       │                                  │                       │
│       │◀── {results: [...]} ────────────│                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### IP Allowlisting

```yaml
# install.yaml
security:
  allowed_ips:
    # GitHub Actions IP ranges
    - "140.82.112.0/20"
    - "143.55.64.0/20"
    # Your office
    - "203.0.113.50/32"
    # WireGuard subnet
    - "10.0.0.0/24"
```

### WireGuard Configuration

```ini
# GPU Host: /etc/wireguard/wg0.conf
[Interface]
PrivateKey = <gpu-host-private-key>
Address = 10.0.0.2/24
ListenPort = 51820

[Peer]
# Test Runner (GitHub self-hosted or CI server)
PublicKey = <test-runner-public-key>
AllowedIPs = 10.0.0.1/32
# If test runner has static IP
Endpoint = runner.example.com:51820
PersistentKeepalive = 25
```

```ini
# Test Runner: /etc/wireguard/wg0.conf
[Interface]
PrivateKey = <test-runner-private-key>
Address = 10.0.0.1/24

[Peer]
# GPU Host
PublicKey = <gpu-host-public-key>
AllowedIPs = 10.0.0.2/32
Endpoint = gpu-host.example.com:51820
PersistentKeepalive = 25
```

---

## Deployment Commands

### Full Installation

```bash
# Interactive mode
./install.sh

# Non-interactive with config file
./install.sh --config install.yaml

# Dry run (show what would happen)
./install.sh --config install.yaml --dry-run
```

### Model Management

```bash
# Pull additional model
./install.sh --pull-model llama-3.2-8B-instruct --quantization Q5_K_M

# List available models
./install.sh --list-models

# Switch default model
./install.sh --set-model mistral-7B-instruct
```

### Stack Management

```bash
# Check status
./install.sh --status

# Restart stack
./install.sh --restart

# View logs
./install.sh --logs

# Update to latest version
./install.sh --update

# Uninstall
./uninstall.sh
```

---

## Lambda Labs Specific Notes

### Quick Start on Lambda A10

```bash
# 1. SSH to Lambda instance
ssh ubuntu@<lambda-ip>

# 2. Clone installer
git clone https://github.com/rng-ops/he300-integration.git
cd he300-integration/installer

# 3. Run installer (Lambda has Docker + NVIDIA pre-installed)
./install.sh --quick-start

# Lambda-specific optimizations applied:
# - Uses Lambda's NVIDIA drivers (no reinstall)
# - Optimizes for A10 24GB VRAM
# - Configures for high-throughput inference
```

### Lambda Stack Detection

```bash
# Installer auto-detects Lambda Stack via:
if [ -f /etc/lambda-stack ]; then
    OS_TYPE="lambda"
    # Skip driver installation
    # Use Lambda's optimized CUDA
fi
```

### A10 24GB Optimization

```yaml
# Automatic configuration for A10:
ollama:
  gpu_layers: -1           # All layers on GPU
  num_parallel: 4          # 4 concurrent requests
  num_ctx: 8192            # Full context window
  
services:
  max_batch_size: 50       # Optimal for A10 memory
  queue_size: 200          # Deep queue for throughput
```

---

## Monitoring & Health Checks

### Health Check Endpoints

```bash
# CIRISNode health
curl http://localhost:8000/health

# EthicsEngine health  
curl http://localhost:8080/health

# Ollama health
curl http://localhost:11434/api/tags

# Full stack health
./scripts/health-check.sh
```

### Prometheus Metrics (Optional)

```yaml
# docker-compose.gpu.yml includes:
services:
  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
  
  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
```

### Alerting

```bash
# Health check runs every 5 minutes via systemd timer
# Sends alert on failure:
./scripts/health-check.sh --alert-webhook https://hooks.slack.com/xxx
```

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| GPU not detected | NVIDIA drivers not loaded | `sudo nvidia-smi` to verify, reinstall drivers if needed |
| OOM during inference | Model too large | Use smaller quantization (Q4_K_M) or smaller model |
| Connection refused | Firewall blocking | Check `ufw status`, allow ports 8000, 8080 |
| WireGuard no handshake | Wrong keys or endpoint | Verify public keys match, check endpoint reachability |
| Slow inference | Wrong GPU layers config | Ensure `gpu_layers: -1` in Ollama config |

### Debug Commands

```bash
# Check GPU utilization
nvidia-smi -l 1

# Check Docker containers
docker ps -a
docker logs cirisnode
docker logs eee
docker logs ollama

# Check WireGuard status
sudo wg show

# Test internal connectivity
docker exec cirisnode curl http://eee:8080/health
docker exec eee curl http://ollama:11434/api/tags
```

---

## Summary

| Mode | Complexity | Security | Best For |
|------|------------|----------|----------|
| Local Dev | Low | N/A | Development, testing |
| Direct HTTPS | Medium | API key + TLS | Cloud GPU with public IP |
| WireGuard | Medium-High | Full encryption | Private GPU, NAT traversal |
| Tailscale | Low | Full encryption | Quick setup, team access |
| Self-hosted Runner | Low | Physical security | GPU machine is CI runner |

### Recommended Setup for Lambda A10

1. **Development**: Local mode with SSH tunnel
2. **CI/CD**: WireGuard VPN with GitHub self-hosted runner
3. **Production**: Direct HTTPS with IP allowlist

### Next Steps

1. **Build installer package** → `scripts/build-installer.sh`
2. **Create systemd units** → `systemd/he300-stack.service`
3. **WireGuard automation** → `config/wireguard/`
4. **Model management CLI** → `scripts/model-manager.sh`
5. **Monitoring stack** → `docker/docker-compose.monitoring.yml`
