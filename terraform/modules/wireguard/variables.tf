# WireGuard VPN Module - Variables

variable "generate_keys" {
  description = "Generate new WireGuard keys (requires wg command)"
  type        = bool
  default     = true
}

variable "output_dir" {
  description = "Directory to write configuration files"
  type        = string
  default     = "./wireguard-configs"
}

# GPU Host configuration
variable "gpu_host_address" {
  description = "WireGuard IP address for GPU host"
  type        = string
  default     = "10.0.0.2/24"
}

variable "gpu_host_private_key" {
  description = "GPU host WireGuard private key (generated if empty)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "gpu_host_public_key" {
  description = "GPU host WireGuard public key"
  type        = string
  default     = ""
}

variable "gpu_host_endpoint" {
  description = "GPU host public IP:port for WireGuard"
  type        = string
  default     = ""
}

variable "listen_port" {
  description = "WireGuard listen port on GPU host"
  type        = number
  default     = 51820
}

# Test Runner configuration
variable "test_runner_address" {
  description = "WireGuard IP address for test runner"
  type        = string
  default     = "10.0.0.1/24"
}

variable "test_runner_private_key" {
  description = "Test runner WireGuard private key (generated if empty)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "test_runner_public_key" {
  description = "Test runner WireGuard public key"
  type        = string
  default     = ""
}

variable "test_runner_endpoint" {
  description = "Test runner public IP:port (optional for dynamic IPs)"
  type        = string
  default     = ""
}

# Connection settings
variable "persistent_keepalive" {
  description = "Persistent keepalive interval in seconds"
  type        = number
  default     = 25
}

# Deployment settings
variable "deploy_to_gpu_host" {
  description = "Deploy configuration to GPU host via SSH"
  type        = bool
  default     = false
}

variable "gpu_host_ssh_host" {
  description = "GPU host SSH address"
  type        = string
  default     = ""
}

variable "gpu_host_ssh_user" {
  description = "GPU host SSH user"
  type        = string
  default     = "ubuntu"
}

variable "gpu_host_ssh_key" {
  description = "GPU host SSH private key"
  type        = string
  default     = ""
  sensitive   = true
}
