provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

module "common" {
  source = "../module"

  environment = "prod"
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}


# IAM instance profile
resource "aws_iam_instance_profile" "ec2_k3s_profile" {
  name = "ec2-k3s-profile-prod"
  role = aws_iam_role.ec2_k3s_role.name

  tags = {
    Name        = "ec2-k3s-profile-prod"
    Environment = "prod"
  }
}

# Security group for master node
resource "aws_security_group" "master_sg" {
  name        = "ec2-k3s-master-sg-prod"
  description = "Security group for k3s master node (prod)"
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

  ingress {
    description = "ArgoCD UI"
    from_port   = 30033
    to_port     = 30033
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ec2-k3s-master-sg-prod"
    Environment = "prod"
  }
}

# Security group for worker nodes
resource "aws_security_group" "worker_sg" {
  name        = "ec2-k3s-worker-sg-prod"
  description = "Security group for k3s worker nodes (prod)"
  vpc_id      = module.common.default_vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ec2-k3s-worker-sg-prod"
    Environment = "prod"
  }
}

# Security group rules for master node (from workers)
resource "aws_security_group_rule" "master_api_from_workers" {
  type                     = "ingress"
  description              = "k3s API server from workers"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker_sg.id
  security_group_id        = aws_security_group.master_sg.id
}

resource "aws_security_group_rule" "master_flannel_from_workers" {
  type                     = "ingress"
  description              = "k3s agent registration (Flannel VXLAN) from workers"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "udp"
  source_security_group_id = aws_security_group.worker_sg.id
  security_group_id        = aws_security_group.master_sg.id
}

resource "aws_security_group_rule" "master_kubelet_from_workers" {
  type                     = "ingress"
  description              = "k3s kubelet from workers"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker_sg.id
  security_group_id        = aws_security_group.master_sg.id
}

# Security group rules for worker nodes (from master and self)
resource "aws_security_group_rule" "worker_flannel_from_master" {
  type                     = "ingress"
  description              = "k3s agent registration (Flannel VXLAN) from master"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "udp"
  source_security_group_id = aws_security_group.master_sg.id
  security_group_id        = aws_security_group.worker_sg.id
}

resource "aws_security_group_rule" "worker_flannel_self" {
  type              = "ingress"
  description       = "k3s agent registration (Flannel VXLAN) from self"
  from_port         = 8472
  to_port           = 8472
  protocol          = "udp"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
}

resource "aws_security_group_rule" "worker_kubelet_from_master" {
  type                     = "ingress"
  description              = "k3s kubelet from master"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.master_sg.id
  security_group_id        = aws_security_group.worker_sg.id
}

resource "aws_security_group_rule" "worker_kubelet_self" {
  type              = "ingress"
  description       = "k3s kubelet from self"
  from_port         = 10250
  to_port           = 10250
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.worker_sg.id
}

# User data script for master node
locals {
  master_user_data = <<-EOF
#!/bin/bash
set -e

# Update system
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates

# Download master setup script directly from GitHub (raw) and run it
MASTER_SCRIPT="/tmp/setup-k3s-master-prod.sh"

# Convert repo URL into "owner/repo" for raw.githubusercontent.com
REPO_PATH="${var.github_repo_url}"
REPO_PATH="$${REPO_PATH#https://github.com/}"
REPO_PATH="$${REPO_PATH#http://github.com/}"
REPO_PATH="$${REPO_PATH#git@github.com:}"
REPO_PATH="$${REPO_PATH%.git}"

RAW_MASTER_URL="https://raw.githubusercontent.com/$${REPO_PATH}/${var.github_repo_branch}/tf/ec2-k3s/setup-k3s-master-prod.sh"
curl -fsSL -o "$MASTER_SCRIPT" "$RAW_MASTER_URL"
chmod +x "$MASTER_SCRIPT"

# Run the master setup script
REPO_URL="${var.github_repo_url}" \
REPO_BRANCH="${var.github_repo_branch}" \
K8S_ENV="prod" \
ARGOCD_ADMIN_PASSWORD="${var.argocd_admin_password}" \
"$MASTER_SCRIPT"
EOF

  worker_user_data = <<-EOF
#!/bin/bash
set -e

# Update system
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates

# Download worker setup script directly from GitHub (raw) and run it
WORKER_SCRIPT="/tmp/setup-k3s-worker-prod.sh"

# Convert repo URL into "owner/repo" for raw.githubusercontent.com
REPO_PATH="${var.github_repo_url}"
REPO_PATH="$${REPO_PATH#https://github.com/}"
REPO_PATH="$${REPO_PATH#http://github.com/}"
REPO_PATH="$${REPO_PATH#git@github.com:}"
REPO_PATH="$${REPO_PATH%.git}"

RAW_WORKER_URL="https://raw.githubusercontent.com/$${REPO_PATH}/${var.github_repo_branch}/tf/ec2-k3s/setup-k3s-worker-prod.sh"
curl -fsSL -o "$WORKER_SCRIPT" "$RAW_WORKER_URL"
chmod +x "$WORKER_SCRIPT"

# Run the worker setup script with environment variables
# Note: master-ip file is created by local_file resource (exists at plan time)
#       k3s-token file is created by wait_for_master_ready provisioner (exists at apply time)
#       Using try() to handle token/IP files not existing during initial plan
K3S_MASTER_IP="${trimspace(try(file("${path.module}/.terraform/master-ip-prod.txt"), ""))}" \
K3S_TOKEN="${trimspace(try(file("${path.module}/.terraform/k3s-token-prod.txt"), ""))}" \
"$WORKER_SCRIPT"
EOF
}

# EC2 instance for master node
resource "aws_instance" "k3s_master" {
  ami                         = module.common.ubuntu_ami_id
  instance_type               = var.master_instance_type
  key_name                    = module.common.ec2_key_pair_name
  vpc_security_group_ids      = [aws_security_group.master_sg.id]
  subnet_id                   = module.common.default_subnet_id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_k3s_profile.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = local.master_user_data

  tags = {
    Name        = "ec2-k3s-master-prod"
    Environment = "prod"
    Role        = "k3s-master"
  }
}

# Wait for master k3s API server to be ready
resource "null_resource" "wait_for_master_ready" {
  depends_on = [aws_instance.k3s_master]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Waiting for master k3s API server to be ready..."
      echo "Using AWS profile: ${var.aws_profile}"
      echo "Using AWS region: ${var.aws_region}"
      
      # Set AWS profile and region
      export AWS_PROFILE="${var.aws_profile}"
      export AWS_DEFAULT_REGION="${var.aws_region}"
      
      # Verify AWS credentials
      if ! aws sts get-caller-identity --region "${var.aws_region}" > /dev/null 2>&1; then
        echo "ERROR: AWS credentials not configured or invalid for profile: ${var.aws_profile}"
        exit 1
      fi
      
      # Get master private IP from instance resource
      MASTER_IP="${aws_instance.k3s_master.private_ip}"
      echo "Master private IP: $MASTER_IP"
      
      # Get master public IP for SSH
      echo "Retrieving master public IP for SSH access..."
      MASTER_PUBLIC_IP=$$(aws ec2 describe-instances \
        --region "${var.aws_region}" \
        --profile "${var.aws_profile}" \
        --filters "Name=tag:Name,Values=ec2-k3s-master-prod" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>&1)
      
      if [ -z "$MASTER_PUBLIC_IP" ] || [ "$MASTER_PUBLIC_IP" = "None" ] || [ "$MASTER_PUBLIC_IP" = "null" ]; then
        echo "ERROR: Could not retrieve master public IP"
        echo "Attempted to query instance with tag Name=ec2-k3s-master-prod"
        exit 1
      fi
      
      echo "Master public IP: $MASTER_PUBLIC_IP"
      
      # Get SSH key path
      SSH_KEY_PATH="${module.common.private_key_file_path}"
      if [ ! -f "$SSH_KEY_PATH" ]; then
        echo "ERROR: SSH key not found at $SSH_KEY_PATH"
        exit 1
      fi
      
      chmod 400 "$SSH_KEY_PATH"
      
      # Wait for SSH to be available
      echo "Waiting for SSH to be available on master node..."
      SSH_ATTEMPT=0
      MAX_SSH_ATTEMPTS=30
      while [ $SSH_ATTEMPT -lt $MAX_SSH_ATTEMPTS ]; do
        if ssh -i "$SSH_KEY_PATH" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=5 \
           -o BatchMode=yes \
           ubuntu@"$MASTER_PUBLIC_IP" \
           "echo 'SSH connection successful'" > /dev/null 2>&1; then
          echo "SSH connection established"
          break
        fi
        SSH_ATTEMPT=$$((SSH_ATTEMPT + 1))
        echo "Waiting for SSH... (attempt $SSH_ATTEMPT/$MAX_SSH_ATTEMPTS)"
        sleep 10
      done
      
      if [ $SSH_ATTEMPT -ge $MAX_SSH_ATTEMPTS ]; then
        echo "ERROR: Could not establish SSH connection to master node after $MAX_SSH_ATTEMPTS attempts"
        echo "Public IP: $MASTER_PUBLIC_IP"
        echo "SSH key: $SSH_KEY_PATH"
        exit 1
      fi
      
      # Wait for API server to be accessible (check from within the master node)
      echo "Testing master API server connectivity from within master node..."
      ATTEMPT=0
      MAX_API_ATTEMPTS=60
      
      while [ $ATTEMPT -lt $MAX_API_ATTEMPTS ]; do
        # Check if k3s service is running and API is responding
        if ssh -i "$SSH_KEY_PATH" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=5 \
           -o BatchMode=yes \
           ubuntu@"$MASTER_PUBLIC_IP" \
           "sudo systemctl is-active --quiet k3s && sudo k3s kubectl get nodes > /dev/null 2>&1" 2>/dev/null; then
          echo "Master API server is ready and responding!"
          
          # Read k3s token from master node
          echo "Reading k3s token from master node..."
          K3S_TOKEN=$$(ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o BatchMode=yes \
             ubuntu@"$MASTER_PUBLIC_IP" \
             "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null)
          
          if [ -z "$K3S_TOKEN" ]; then
            echo "ERROR: Failed to read k3s token from master node"
            exit 1
          fi
          
          # Trim any whitespace from token
          K3S_TOKEN=$$(echo "$K3S_TOKEN" | tr -d '\r\n' | xargs)
          
          if [ -z "$K3S_TOKEN" ]; then
            echo "ERROR: k3s token is empty after trimming"
            exit 1
          fi
          
          TOKEN_LENGTH=$${#K3S_TOKEN}
          echo "Successfully read k3s token from master node (length: $TOKEN_LENGTH characters)"
          
          # Create .terraform directory if it doesn't exist
          mkdir -p "${path.module}/.terraform"
          
          # Write token to local file
          TOKEN_FILE="${path.module}/.terraform/k3s-token-prod.txt"
          echo "$K3S_TOKEN" > "$TOKEN_FILE"
          chmod 600 "$TOKEN_FILE"
          
          # Verify token was written correctly
          if [ ! -f "$TOKEN_FILE" ]; then
            echo "ERROR: Failed to create token file at $TOKEN_FILE"
            exit 1
          fi
          
          VERIFIED_TOKEN=$$(cat "$TOKEN_FILE" | tr -d '\r\n' | xargs)
          if [ "$VERIFIED_TOKEN" != "$K3S_TOKEN" ]; then
            echo "ERROR: Token verification failed - written token does not match read token"
            exit 1
          fi
          
          echo "✓ k3s token successfully stored to $TOKEN_FILE"
          echo "  Token file permissions: $$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%A' "$TOKEN_FILE" 2>/dev/null)"
          echo "  Token file size: $$(stat -c '%s' "$TOKEN_FILE" 2>/dev/null || stat -f '%z' "$TOKEN_FILE" 2>/dev/null) bytes"
          
          exit 0
        fi
        
        ATTEMPT=$$((ATTEMPT + 1))
        echo "Master API not ready yet... (attempt $ATTEMPT/$MAX_API_ATTEMPTS)"
        sleep 10
      done
      
      echo "ERROR: Master API server not ready after $MAX_API_ATTEMPTS attempts"
      echo "Checking k3s service status..."
      ssh -i "$SSH_KEY_PATH" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes \
          ubuntu@"$MASTER_PUBLIC_IP" \
          "sudo systemctl status k3s --no-pager -l || true" || true
      exit 1
    EOT
  }

  triggers = {
    master_instance_id = aws_instance.k3s_master.id
  }
}

# Write master IP to local file
resource "local_file" "master_ip" {
  depends_on = [aws_instance.k3s_master]
  
  content  = aws_instance.k3s_master.private_ip
  filename = "${path.module}/.terraform/master-ip-prod.txt"
  
  file_permission = "0644"
}

# Log master IP storage
resource "null_resource" "log_master_ip_storage" {
  depends_on = [local_file.master_ip]
  
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      MASTER_IP_FILE="${path.module}/.terraform/master-ip-prod.txt"
      
      if [ ! -f "$MASTER_IP_FILE" ]; then
        echo "ERROR: Master IP file not found at $MASTER_IP_FILE"
        exit 1
      fi
      
      MASTER_IP=$$(cat "$MASTER_IP_FILE" | tr -d '\r\n' | xargs)
      
      if [ -z "$MASTER_IP" ]; then
        echo "ERROR: Master IP file is empty"
        exit 1
      fi
      
      # Validate IP format (basic check)
      if ! echo "$MASTER_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "WARNING: Master IP format may be invalid: $MASTER_IP"
      fi
      
      echo "✓ Master IP successfully stored to $MASTER_IP_FILE"
      echo "  Master private IP: $MASTER_IP"
      echo "  IP file permissions: $$(stat -c '%a' "$MASTER_IP_FILE" 2>/dev/null || stat -f '%A' "$MASTER_IP_FILE" 2>/dev/null)"
      echo "  IP file size: $$(stat -c '%s' "$MASTER_IP_FILE" 2>/dev/null || stat -f '%z' "$MASTER_IP_FILE" 2>/dev/null) bytes"
    EOT
  }
  
  triggers = {
    master_ip_file = local_file.master_ip.content
  }
}

# Note: k3s token file is written by wait_for_master_ready provisioner
# and will be read directly in worker_user_data using file() function

# Launch template for worker nodes
resource "aws_launch_template" "k3s_worker" {
  name_prefix   = "k3s-worker-prod-"
  image_id      = module.common.ubuntu_ami_id
  instance_type = var.worker_instance_type
  key_name      = module.common.ec2_key_pair_name

  vpc_security_group_ids = [aws_security_group.worker_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_k3s_profile.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
  }

  user_data = base64encode(local.worker_user_data)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "ec2-k3s-worker-prod"
      Environment = "prod"
      Role        = "k3s-worker"
    }
  }

  tags = {
    Name        = "k3s-worker-launch-template-prod"
    Environment = "prod"
  }
}

# Auto Scaling Group for worker nodes
resource "aws_autoscaling_group" "k3s_workers" {
  name                = "k3s-workers-prod"
  vpc_zone_identifier = [module.common.default_subnet_id]
  target_group_arns   = []
  health_check_type   = "EC2"
  health_check_grace_period = 300

  min_size         = var.worker_desired_capacity
  max_size         = var.worker_desired_capacity
  desired_capacity = var.worker_desired_capacity

  launch_template {
    id      = aws_launch_template.k3s_worker.id
    version = "$Latest"
  }

  depends_on = [
    aws_instance.k3s_master,
    null_resource.wait_for_master_ready,
    local_file.master_ip,
    null_resource.log_master_ip_storage
  ]

  tag {
    key                 = "Name"
    value               = "k3s-worker-prod"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "prod"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "k3s-worker"
    propagate_at_launch = true
  }

  # Wait for instances to be healthy before considering ASG ready
  wait_for_capacity_timeout = "10m"
}

