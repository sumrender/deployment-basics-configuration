module "ec2_k3s" {
  source = "../module"

  environment = "dev"
  k8s_env     = "dev"

  aws_region  = var.aws_region
  aws_profile = var.aws_profile

  instance_type     = var.instance_type
  allowed_ssh_cidr  = var.allowed_ssh_cidr
  github_repo_url    = var.github_repo_url
  github_repo_branch = var.github_repo_branch
}

