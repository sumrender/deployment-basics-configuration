provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

module "common" {
  source = "../module"

  environment = "dev"
}

# Security group for EC2 instance
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-k3s-cluster-sg-dev"
  description = "Security group for EC2 instance running k3s cluster (dev)"
  vpc_id      = module.common.default_vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP (Caddy)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (Caddy)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ec2-k3s-cluster-sg-dev"
    Environment = "dev"
  }
}

# User data script to clone repo and run bootstrap script
locals {
  user_data = <<-EOF
#!/bin/bash
set -e

# Update system
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates

# Download bootstrap script directly from GitHub (raw) and run it
BOOTSTRAP_SCRIPT="/tmp/bootstrap-k3s-ec2.sh"

# Convert repo URL into "owner/repo" for raw.githubusercontent.com
REPO_PATH="${var.github_repo_url}"
REPO_PATH="$${REPO_PATH#https://github.com/}"
REPO_PATH="$${REPO_PATH#http://github.com/}"
REPO_PATH="$${REPO_PATH#git@github.com:}"
REPO_PATH="$${REPO_PATH%.git}"

RAW_BOOTSTRAP_URL="https://raw.githubusercontent.com/$${REPO_PATH}/${var.github_repo_branch}/tf/ec2-k3s/bootstrap-k3s-ec2.sh"
curl -fsSL -o "$BOOTSTRAP_SCRIPT" "$RAW_BOOTSTRAP_URL"
chmod +x "$BOOTSTRAP_SCRIPT"

# Run the bootstrap script with K8S_ENV environment variable
REPO_URL="${var.github_repo_url}" REPO_BRANCH="${var.github_repo_branch}" K8S_ENV="dev" "$BOOTSTRAP_SCRIPT"
EOF
}

# EC2 instance
resource "aws_instance" "k3s_cluster" {
  ami                         = module.common.ubuntu_ami_id
  instance_type               = var.instance_type
  key_name                    = module.common.ec2_key_pair_name
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  subnet_id                   = module.common.default_subnet_id
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = local.user_data

  tags = {
    Name        = "ec2-k3s-cluster-dev"
    Environment = "dev"
  }
}

