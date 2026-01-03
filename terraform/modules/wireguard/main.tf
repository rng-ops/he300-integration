# WireGuard VPN Module - Main Configuration
# Sets up WireGuard VPN between GPU host and test runners

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

locals {
  # Generate WireGuard keys if not provided
  gpu_host_private_key    = var.gpu_host_private_key != "" ? var.gpu_host_private_key : null
  test_runner_private_key = var.test_runner_private_key != "" ? var.test_runner_private_key : null
}

# Generate WireGuard keys using external data source
data "external" "wg_keys" {
  count = var.generate_keys ? 1 : 0

  program = ["bash", "-c", <<-EOF
    GPU_PRIVATE=$(wg genkey)
    GPU_PUBLIC=$(echo $GPU_PRIVATE | wg pubkey)
    RUNNER_PRIVATE=$(wg genkey)
    RUNNER_PUBLIC=$(echo $RUNNER_PRIVATE | wg pubkey)
    
    echo "{\"gpu_private\":\"$GPU_PRIVATE\",\"gpu_public\":\"$GPU_PUBLIC\",\"runner_private\":\"$RUNNER_PRIVATE\",\"runner_public\":\"$RUNNER_PUBLIC\"}"
  EOF
  ]
}

# GPU Host WireGuard configuration
resource "local_file" "gpu_host_config" {
  filename = "${var.output_dir}/wg0-gpu-host.conf"

  content = templatefile("${path.module}/templates/wg0.conf.tpl", {
    interface_private_key = var.generate_keys ? data.external.wg_keys[0].result.gpu_private : var.gpu_host_private_key
    interface_address     = var.gpu_host_address
    listen_port           = var.listen_port
    peer_public_key       = var.generate_keys ? data.external.wg_keys[0].result.runner_public : var.test_runner_public_key
    peer_allowed_ips      = var.test_runner_address
    peer_endpoint         = var.test_runner_endpoint
    persistent_keepalive  = var.persistent_keepalive
    is_server             = true
  })

  file_permission = "0600"
}

# Test Runner WireGuard configuration
resource "local_file" "test_runner_config" {
  filename = "${var.output_dir}/wg0-test-runner.conf"

  content = templatefile("${path.module}/templates/wg0.conf.tpl", {
    interface_private_key = var.generate_keys ? data.external.wg_keys[0].result.runner_private : var.test_runner_private_key
    interface_address     = var.test_runner_address
    listen_port           = 0 # Client doesn't need fixed port
    peer_public_key       = var.generate_keys ? data.external.wg_keys[0].result.gpu_public : var.gpu_host_public_key
    peer_allowed_ips      = var.gpu_host_address
    peer_endpoint         = var.gpu_host_endpoint
    persistent_keepalive  = var.persistent_keepalive
    is_server             = false
  })

  file_permission = "0600"
}

# Deploy to GPU host via SSH
resource "null_resource" "deploy_gpu_host" {
  count = var.deploy_to_gpu_host ? 1 : 0

  depends_on = [local_file.gpu_host_config]

  triggers = {
    config_hash = sha256(local_file.gpu_host_config.content)
  }

  connection {
    type        = "ssh"
    user        = var.gpu_host_ssh_user
    private_key = var.gpu_host_ssh_key
    host        = var.gpu_host_ssh_host
    timeout     = "5m"
  }

  provisioner "file" {
    source      = local_file.gpu_host_config.filename
    destination = "/tmp/wg0.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/wg0.conf /etc/wireguard/wg0.conf",
      "sudo chmod 600 /etc/wireguard/wg0.conf",
      "sudo systemctl enable wg-quick@wg0",
      "sudo systemctl restart wg-quick@wg0 || sudo wg-quick up wg0",
      "sleep 2",
      "sudo wg show wg0"
    ]
  }
}
