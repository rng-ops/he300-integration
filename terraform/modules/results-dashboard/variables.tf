# Results Dashboard Module - Variables

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS"
  type        = list(string)
  default     = []
}

variable "dashboard_security_group_ids" {
  description = "Security group IDs that can access RDS"
  type        = list(string)
  default     = []
}

# S3 Configuration
variable "artifact_retention_days" {
  description = "Number of days to retain artifacts in S3"
  type        = number
  default     = 90
}

# RDS Configuration
variable "deploy_rds" {
  description = "Deploy managed RDS PostgreSQL"
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
  default     = ""
}

# ECS Configuration
variable "deploy_ecs" {
  description = "Deploy ECS cluster and ECR repository"
  type        = bool
  default     = false
}

# CloudFront Configuration
variable "deploy_cloudfront" {
  description = "Deploy CloudFront distribution"
  type        = bool
  default     = false
}

variable "dashboard_origin_domain" {
  description = "Origin domain for CloudFront"
  type        = string
  default     = ""
}
