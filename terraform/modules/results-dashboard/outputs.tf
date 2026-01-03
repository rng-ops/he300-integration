# Results Dashboard Module - Outputs

output "artifacts_bucket_name" {
  description = "S3 bucket name for artifacts"
  value       = aws_s3_bucket.artifacts.id
}

output "artifacts_bucket_arn" {
  description = "S3 bucket ARN for artifacts"
  value       = aws_s3_bucket.artifacts.arn
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = var.deploy_rds ? aws_db_instance.dashboard[0].endpoint : null
}

output "rds_database_name" {
  description = "RDS database name"
  value       = var.deploy_rds ? aws_db_instance.dashboard[0].db_name : null
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = var.deploy_ecs ? aws_ecr_repository.dashboard[0].repository_url : null
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = var.deploy_ecs ? aws_ecs_cluster.dashboard[0].name : null
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain"
  value       = var.deploy_cloudfront ? aws_cloudfront_distribution.dashboard[0].domain_name : null
}

output "dashboard_role_arn" {
  description = "IAM role ARN for dashboard"
  value       = aws_iam_role.dashboard.arn
}
