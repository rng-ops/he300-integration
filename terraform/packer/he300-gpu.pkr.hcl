# HE-300 GPU Host Packer Build
# Creates pre-configured AMI with Docker, NVIDIA, and HE-300 stack

packer {
  required_version = ">= 1.9.0"
  
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# Variables
variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "aws_access_key" {
  type    = string
  default = env("AWS_ACCESS_KEY_ID")
}

variable "aws_secret_key" {
  type      = string
  default   = env("AWS_SECRET_ACCESS_KEY")
  sensitive = true
}

variable "vault_addr" {
  type    = string
  default = env("VAULT_ADDR")
}

variable "base_ami_name" {
  type    = string
  default = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
}

variable "instance_type" {
  type    = string
  default = "g5.xlarge"  # NVIDIA A10G
}

variable "volume_size" {
  type    = number
  default = 200
}

variable "ami_prefix" {
  type    = string
  default = "he300-gpu"
}

variable "docker_images" {
  type = list(string)
  default = [
    "ghcr.io/rng-ops/cirisnode:latest",
    "ghcr.io/rng-ops/ethicsengine:latest",
    "ollama/ollama:latest",
    "postgres:15-alpine",
    "redis:7-alpine"
  ]
}

variable "default_model" {
  type    = string
  default = "llama3.2:3b-instruct-q4_K_M"
}

# Data sources
data "amazon-ami" "ubuntu" {
  filters = {
    name                = var.base_ami_name
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  region      = var.aws_region
}

# Builder
source "amazon-ebs" "he300_gpu" {
  access_key    = var.aws_access_key
  secret_key    = var.aws_secret_key
  region        = var.aws_region
  
  source_ami    = data.amazon-ami.ubuntu.id
  instance_type = var.instance_type
  ssh_username  = "ubuntu"
  
  ami_name        = "${var.ami_prefix}-{{timestamp}}"
  ami_description = "HE-300 Benchmark GPU Image with CIRISNode + EthicsEngine + Ollama"
  
  ami_regions = [var.aws_region]
  
  tags = {
    Name        = "${var.ami_prefix}-{{timestamp}}"
    Project     = "he300-benchmark"
    BuildTime   = "{{timestamp}}"
    BaseAMI     = "{{ .SourceAMI }}"
    SourceAMIName = "{{ .SourceAMIName }}"
  }
  
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }
  
  # Spot instance for cheaper builds
  spot_price                  = "auto"
  spot_instance_types         = ["g5.xlarge", "g5.2xlarge"]
  spot_price                  = "1.50"
  
  # AMI sharing (optional)
  # ami_users = ["123456789012"]
}

# Build
build {
  sources = ["source.amazon-ebs.he300_gpu"]
  
  # Wait for cloud-init to complete
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init...'",
      "cloud-init status --wait",
      "echo 'Cloud-init complete'"
    ]
  }
  
  # System updates
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y curl wget git jq unzip htop net-tools wireguard"
    ]
  }
  
  # Install Docker
  provisioner "shell" {
    script = "${path.root}/scripts/install-docker.sh"
  }
  
  # Install NVIDIA drivers and container toolkit
  provisioner "shell" {
    script = "${path.root}/scripts/install-nvidia.sh"
  }
  
  # Install Vault CLI
  provisioner "shell" {
    inline = [
      "curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list",
      "sudo apt-get update",
      "sudo apt-get install -y vault"
    ]
  }
  
  # Create HE-300 directories
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/he300",
      "sudo chown ubuntu:ubuntu /opt/he300"
    ]
  }
  
  # Copy installer files
  provisioner "file" {
    source      = "${path.root}/../../installer/"
    destination = "/opt/he300/"
  }
  
  # Pre-pull Docker images
  provisioner "shell" {
    inline = concat(
      ["echo 'Pulling Docker images...'"],
      [for image in var.docker_images : "sudo docker pull ${image}"]
    )
  }
  
  # Install Ollama and pre-pull model
  provisioner "shell" {
    inline = [
      "echo 'Installing Ollama...'",
      "curl -fsSL https://ollama.com/install.sh | sh",
      "sudo systemctl enable ollama",
      "sudo systemctl start ollama",
      "sleep 5",
      "ollama pull ${var.default_model} || echo 'Model pull will happen on first run'"
    ]
  }
  
  # Setup systemd service
  provisioner "shell" {
    script = "${path.root}/scripts/install-he300.sh"
  }
  
  # Cleanup
  provisioner "shell" {
    inline = [
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo rm -rf /tmp/*",
      "echo 'Build complete!'"
    ]
  }
  
  # Manifest for tracking builds
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      version     = "1.0.0"
      model       = var.default_model
      vault_ready = var.vault_addr != "" ? "true" : "false"
    }
  }
}
