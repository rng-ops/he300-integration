# GPU Instance Module - Variables

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cloud_provider" {
  description = "Cloud provider (aws, lambda)"
  type        = string
  default     = "aws"
  
  validation {
    condition     = contains(["aws", "lambda"], var.cloud_provider)
    error_message = "Cloud provider must be 'aws' or 'lambda'."
  }
}

variable "gpu_type" {
  description = "GPU type (a10, a10-2x, a100, t4)"
  type        = string
  default     = "a10"
}

variable "use_deep_learning_ami" {
  description = "Use AWS Deep Learning AMI with pre-installed NVIDIA drivers"
  type        = bool
  default     = true
}

variable "root_volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 200
}

variable "ssh_key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "ssh_private_key" {
  description = "SSH private key for remote provisioning"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID for the instance"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the instance"
  type        = string
}

variable "assign_elastic_ip" {
  description = "Assign an Elastic IP to the instance"
  type        = bool
  default     = true
}

variable "iam_instance_profile" {
  description = "IAM instance profile name"
  type        = string
  default     = ""
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed SSH access"
  type        = list(string)
  default     = []
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed API access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vault_addr" {
  description = "HashiCorp Vault server address"
  type        = string
  default     = ""
}

variable "vault_role_id" {
  description = "Vault AppRole role ID for authentication"
  type        = string
  default     = ""
  sensitive   = true
}

variable "docker_compose_url" {
  description = "URL to download docker-compose.yml"
  type        = string
  default     = "https://raw.githubusercontent.com/rng-ops/he300-integration/main/docker/docker-compose.gpu.yml"
}

variable "default_model" {
  description = "Default LLM model to pull"
  type        = string
  default     = "llama3.2:3b-instruct-q4_K_M"
}

variable "quantization" {
  description = "Model quantization level"
  type        = string
  default     = "Q4_K_M"
}

variable "enable_dashboard" {
  description = "Enable results dashboard on this instance"
  type        = bool
  default     = false
}

variable "enable_monitoring" {
  description = "Enable CloudWatch monitoring and alarms"
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  type        = string
  default     = ""
}

# Lambda Labs specific variables
variable "lambda_api_key" {
  description = "Lambda Labs API key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "lambda_region" {
  description = "Lambda Labs region"
  type        = string
  default     = "us-west-1"
}

variable "lambda_instance_type" {
  description = "Lambda Labs instance type"
  type        = string
  default     = "gpu_1x_a10"
}
