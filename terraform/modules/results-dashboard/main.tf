# Results Dashboard Module - Main Configuration
# Deploys the HE-300 results dashboard infrastructure

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  name_prefix = "he300-dashboard-${var.environment}"

  common_tags = {
    Environment = var.environment
    Project     = "he300-benchmark"
    ManagedBy   = "terraform"
    Component   = "dashboard"
  }
}

# S3 Bucket for artifacts
resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.name_prefix}-artifacts"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-artifacts"
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.artifact_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# RDS PostgreSQL for dashboard data
resource "aws_db_subnet_group" "dashboard" {
  count = var.deploy_rds ? 1 : 0

  name       = "${local.name_prefix}-db-subnet"
  subnet_ids = var.private_subnet_ids

  tags = local.common_tags
}

resource "aws_security_group" "rds" {
  count = var.deploy_rds ? 1 : 0

  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for dashboard RDS"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from dashboard"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.dashboard_security_group_ids
  }

  tags = local.common_tags
}

resource "aws_db_instance" "dashboard" {
  count = var.deploy_rds ? 1 : 0

  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = "15"
  instance_class = var.rds_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "he300_dashboard"
  username = "dashboard"
  password = var.rds_password

  db_subnet_group_name   = aws_db_subnet_group.dashboard[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name_prefix}-final" : null

  deletion_protection = var.environment == "prod"

  tags = local.common_tags
}

# ECS Cluster for dashboard (optional)
resource "aws_ecs_cluster" "dashboard" {
  count = var.deploy_ecs ? 1 : 0

  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

# ECR Repository for dashboard image
resource "aws_ecr_repository" "dashboard" {
  count = var.deploy_ecs ? 1 : 0

  name                 = "he300-dashboard"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "dashboard" {
  count = var.deploy_ecs ? 1 : 0

  repository = aws_ecr_repository.dashboard[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# CloudFront distribution for dashboard (optional)
resource "aws_cloudfront_distribution" "dashboard" {
  count = var.deploy_cloudfront ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "HE-300 Dashboard CDN"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name = var.dashboard_origin_domain
    origin_id   = "dashboard"

    custom_origin_config {
      http_port              = 3000
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "dashboard"

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.common_tags
}

# IAM role for dashboard to access S3
resource "aws_iam_role" "dashboard" {
  name = "${local.name_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "dashboard_s3" {
  name = "${local.name_prefix}-s3-policy"
  role = aws_iam_role.dashboard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      }
    ]
  })
}
