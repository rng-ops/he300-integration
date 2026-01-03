# GPU Instance Module - Main Configuration
# Provisions GPU instances on Lambda Labs or AWS

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

locals {
  instance_name = "he300-gpu-${var.environment}"
  
  common_tags = {
    Environment = var.environment
    Project     = "he300-benchmark"
    ManagedBy   = "terraform"
    Component   = "gpu-instance"
  }
  
  # GPU instance type mapping
  aws_gpu_types = {
    "a10"     = "g5.xlarge"      # NVIDIA A10G 24GB
    "a10-2x"  = "g5.2xlarge"     # NVIDIA A10G 24GB, more CPU/RAM
    "a100"    = "p4d.24xlarge"   # NVIDIA A100 40GB x8
    "t4"      = "g4dn.xlarge"    # NVIDIA T4 16GB
  }
}

# Data source for Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  count       = var.cloud_provider == "aws" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Data source for Deep Learning AMI (pre-installed NVIDIA drivers)
data "aws_ami" "deep_learning" {
  count       = var.cloud_provider == "aws" && var.use_deep_learning_ami ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) *"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# AWS GPU Instance
resource "aws_instance" "gpu" {
  count = var.cloud_provider == "aws" ? 1 : 0

  ami           = var.use_deep_learning_ami ? data.aws_ami.deep_learning[0].id : data.aws_ami.ubuntu[0].id
  instance_type = lookup(local.aws_gpu_types, var.gpu_type, "g5.xlarge")
  
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.gpu[0].id]
  subnet_id              = var.subnet_id
  
  iam_instance_profile = var.iam_instance_profile
  
  user_data = base64encode(templatefile("${path.module}/templates/userdata.sh.tpl", {
    environment        = var.environment
    vault_addr         = var.vault_addr
    vault_role_id      = var.vault_role_id
    docker_compose_url = var.docker_compose_url
    install_nvidia     = !var.use_deep_learning_ami
    gpu_type           = var.gpu_type
    default_model      = var.default_model
    quantization       = var.quantization
  }))

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(local.common_tags, {
    Name    = local.instance_name
    GPUType = var.gpu_type
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# Elastic IP for stable addressing
resource "aws_eip" "gpu" {
  count = var.cloud_provider == "aws" && var.assign_elastic_ip ? 1 : 0
  
  instance = aws_instance.gpu[0].id
  domain   = "vpc"
  
  tags = merge(local.common_tags, {
    Name = "${local.instance_name}-eip"
  })
}

# Security Group
resource "aws_security_group" "gpu" {
  count = var.cloud_provider == "aws" ? 1 : 0

  name        = "${local.instance_name}-sg"
  description = "Security group for HE-300 GPU instance"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  # CIRISNode API
  ingress {
    description = "CIRISNode API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # EthicsEngine API
  ingress {
    description = "EthicsEngine API"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # WireGuard
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Dashboard (if enabled)
  dynamic "ingress" {
    for_each = var.enable_dashboard ? [1] : []
    content {
      description = "Results Dashboard"
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidrs
    }
  }

  # HTTPS (for reverse proxy)
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # Egress - allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.instance_name}-sg"
  })
}

# Wait for instance to be ready
resource "null_resource" "wait_for_instance" {
  count = var.cloud_provider == "aws" ? 1 : 0

  depends_on = [aws_instance.gpu]

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait",
      "echo 'Cloud-init complete'"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = var.ssh_private_key
      host        = var.assign_elastic_ip ? aws_eip.gpu[0].public_ip : aws_instance.gpu[0].public_ip
      timeout     = "10m"
    }
  }
}

# CloudWatch alarms for monitoring
resource "aws_cloudwatch_metric_alarm" "gpu_cpu" {
  count = var.cloud_provider == "aws" && var.enable_monitoring ? 1 : 0

  alarm_name          = "${local.instance_name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "High CPU utilization on HE-300 GPU instance"

  dimensions = {
    InstanceId = aws_instance.gpu[0].id
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []
  ok_actions    = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = local.common_tags
}
