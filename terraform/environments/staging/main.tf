# HE-300 Staging Environment
# Terraform configuration for staging environment

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
  
  backend "s3" {
    bucket         = "he300-terraform-state"
    key            = "staging/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "he300-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Environment = "staging"
      Project     = "he300-benchmark"
      ManagedBy   = "terraform"
    }
  }
}

provider "vault" {
  address = var.vault_addr
}

# Variables
variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_subnet_ids" {
  type    = list(string)
  default = []
}

variable "ssh_key_name" {
  type = string
}

variable "admin_cidrs" {
  type    = list(string)
  default = []
}

variable "allowed_cidrs" {
  type    = list(string)
  default = []
}

variable "vault_addr" {
  type = string
}

variable "vault_role_id" {
  type      = string
  sensitive = true
}

variable "rds_password" {
  type      = string
  sensitive = true
}

# GPU Instance
module "gpu_instance" {
  source = "../../modules/gpu-instance"
  
  environment = "staging"
  
  cloud_provider        = "aws"
  gpu_type              = "a10"
  use_deep_learning_ami = true
  root_volume_size      = 200
  
  vpc_id       = var.vpc_id
  subnet_id    = var.subnet_id
  ssh_key_name = var.ssh_key_name
  
  admin_cidrs   = var.admin_cidrs
  allowed_cidrs = var.allowed_cidrs
  
  assign_elastic_ip = true
  enable_dashboard  = true
  enable_monitoring = true
  
  vault_addr    = var.vault_addr
  vault_role_id = var.vault_role_id
  default_model = "llama3.2:3b-instruct-q4_K_M"
  quantization  = "Q4_K_M"
}

# WireGuard VPN
module "wireguard" {
  source = "../../modules/wireguard"
  
  generate_keys     = true
  output_dir        = "${path.module}/wireguard-configs"
  
  gpu_host_address     = "10.0.0.2/24"
  gpu_host_endpoint    = "${module.gpu_instance.instance_public_ip}:51820"
  test_runner_address  = "10.0.0.1/24"
  
  deploy_to_gpu_host   = true
  gpu_host_ssh_host    = module.gpu_instance.instance_public_ip
  gpu_host_ssh_user    = "ubuntu"
}

# Results Dashboard
module "dashboard" {
  source = "../../modules/results-dashboard"
  
  environment = "staging"
  vpc_id      = var.vpc_id
  
  artifact_retention_days      = 90
  private_subnet_ids           = var.private_subnet_ids
  dashboard_security_group_ids = [module.gpu_instance.security_group_id]
  
  # RDS in staging
  deploy_rds       = true
  rds_instance_class = "db.t3.small"
  rds_password     = var.rds_password
  
  # ECR for container images
  deploy_ecs       = true
  
  # No CloudFront in staging
  deploy_cloudfront = false
}

# Outputs
output "gpu_instance_ip" {
  value = module.gpu_instance.instance_public_ip
}

output "cirisnode_url" {
  value = module.gpu_instance.cirisnode_url
}

output "ethicsengine_url" {
  value = module.gpu_instance.ethicsengine_url
}

output "dashboard_url" {
  value = module.gpu_instance.dashboard_url
}

output "vpn_cirisnode_url" {
  value = module.wireguard.vpn_cirisnode_url
}

output "rds_endpoint" {
  value = module.dashboard.rds_endpoint
}

output "ecr_repository" {
  value = module.dashboard.ecr_repository_url
}

output "artifacts_bucket" {
  value = module.dashboard.artifacts_bucket_name
}
