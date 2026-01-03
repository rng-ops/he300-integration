# HE-300 Development Environment
# Terraform configuration for dev environment

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 3.0"
    }
  }

  # Backend configuration - uncomment and configure for remote state
  # backend "s3" {
  #   bucket         = "he300-terraform-state"
  #   key            = "dev/terraform.tfstate"
  #   region         = "us-west-2"
  #   encrypt        = true
  #   dynamodb_table = "he300-terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "he300-benchmark"
      ManagedBy   = "terraform"
    }
  }
}

# Optional: Vault provider for secrets
# provider "vault" {
#   address = var.vault_addr
# }

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for GPU instance"
  type        = string
}

variable "ssh_key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "admin_cidrs" {
  description = "CIDR blocks for admin SSH access"
  type        = list(string)
  default     = []
}

variable "vault_addr" {
  description = "Vault server address"
  type        = string
  default     = ""
}

# GPU Instance
module "gpu_instance" {
  source = "../../modules/gpu-instance"

  environment = "dev"

  cloud_provider        = "aws"
  gpu_type              = "a10"
  use_deep_learning_ami = true
  root_volume_size      = 200

  vpc_id       = var.vpc_id
  subnet_id    = var.subnet_id
  ssh_key_name = var.ssh_key_name

  admin_cidrs   = var.admin_cidrs
  allowed_cidrs = ["0.0.0.0/0"] # Dev environment - open access

  assign_elastic_ip = true
  enable_dashboard  = true
  enable_monitoring = false # Disable CloudWatch in dev

  vault_addr    = var.vault_addr
  default_model = "llama3.2:3b-instruct-q4_K_M"
  quantization  = "Q4_K_M"
}

# WireGuard VPN (optional for dev)
module "wireguard" {
  source = "../../modules/wireguard"

  generate_keys = true
  output_dir    = "${path.module}/wireguard-configs"

  gpu_host_address    = "10.0.0.2/24"
  test_runner_address = "10.0.0.1/24"

  # Don't auto-deploy in dev
  deploy_to_gpu_host = false
}

# Results Dashboard infrastructure
module "dashboard" {
  source = "../../modules/results-dashboard"

  environment = "dev"

  # S3 only in dev (no RDS, ECS, CloudFront)
  artifact_retention_days = 30
  deploy_rds              = false
  deploy_ecs              = false
  deploy_cloudfront       = false
}

# Outputs
output "gpu_instance_ip" {
  description = "GPU instance public IP"
  value       = module.gpu_instance.instance_public_ip
}

output "cirisnode_url" {
  description = "CIRISNode API URL"
  value       = module.gpu_instance.cirisnode_url
}

output "ethicsengine_url" {
  description = "EthicsEngine API URL"
  value       = module.gpu_instance.ethicsengine_url
}

output "dashboard_url" {
  description = "Dashboard URL"
  value       = module.gpu_instance.dashboard_url
}

output "ssh_command" {
  description = "SSH connection command"
  value       = module.gpu_instance.ssh_connection
}

output "wireguard_gpu_host_key" {
  description = "WireGuard GPU host public key"
  value       = module.wireguard.gpu_host_public_key
  sensitive   = true
}

output "wireguard_test_runner_key" {
  description = "WireGuard test runner public key"
  value       = module.wireguard.test_runner_public_key
  sensitive   = true
}

output "artifacts_bucket" {
  description = "S3 bucket for artifacts"
  value       = module.dashboard.artifacts_bucket_name
}
