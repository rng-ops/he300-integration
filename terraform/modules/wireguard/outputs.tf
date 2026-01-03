# WireGuard VPN Module - Outputs

output "gpu_host_public_key" {
  description = "GPU host WireGuard public key"
  value       = var.generate_keys ? data.external.wg_keys[0].result.gpu_public : var.gpu_host_public_key
}

output "test_runner_public_key" {
  description = "Test runner WireGuard public key"
  value       = var.generate_keys ? data.external.wg_keys[0].result.runner_public : var.test_runner_public_key
}

output "gpu_host_config_path" {
  description = "Path to GPU host WireGuard configuration"
  value       = local_file.gpu_host_config.filename
}

output "test_runner_config_path" {
  description = "Path to test runner WireGuard configuration"
  value       = local_file.test_runner_config.filename
}

output "gpu_host_vpn_ip" {
  description = "GPU host VPN IP address"
  value       = split("/", var.gpu_host_address)[0]
}

output "test_runner_vpn_ip" {
  description = "Test runner VPN IP address"
  value       = split("/", var.test_runner_address)[0]
}

output "vpn_cirisnode_url" {
  description = "CIRISNode URL via VPN"
  value       = "http://${split("/", var.gpu_host_address)[0]}:8000"
}

output "vpn_ethicsengine_url" {
  description = "EthicsEngine URL via VPN"
  value       = "http://${split("/", var.gpu_host_address)[0]}:8080"
}
