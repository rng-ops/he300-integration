# GPU Instance Module - Outputs

output "instance_id" {
  description = "Instance ID"
  value       = var.cloud_provider == "aws" ? aws_instance.gpu[0].id : null
}

output "instance_public_ip" {
  description = "Public IP address"
  value = var.cloud_provider == "aws" ? (
    var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip
  ) : null
}

output "instance_private_ip" {
  description = "Private IP address"
  value       = var.cloud_provider == "aws" ? aws_instance.gpu[0].private_ip : null
}

output "security_group_id" {
  description = "Security group ID"
  value       = var.cloud_provider == "aws" ? aws_security_group.gpu[0].id : null
}

output "cirisnode_url" {
  description = "CIRISNode API URL"
  value = var.cloud_provider == "aws" ? (
    "http://${var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip}:8000"
  ) : null
}

output "ethicsengine_url" {
  description = "EthicsEngine API URL"
  value = var.cloud_provider == "aws" ? (
    "http://${var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip}:8080"
  ) : null
}

output "dashboard_url" {
  description = "Results Dashboard URL"
  value = var.cloud_provider == "aws" && var.enable_dashboard ? (
    "http://${var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip}:3000"
  ) : null
}

output "ssh_connection" {
  description = "SSH connection command"
  value = var.cloud_provider == "aws" ? (
    "ssh -i ~/.ssh/${var.ssh_key_name}.pem ubuntu@${var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip}"
  ) : null
}

output "wireguard_endpoint" {
  description = "WireGuard endpoint"
  value = var.cloud_provider == "aws" ? (
    "${var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip}:51820"
  ) : null
}
