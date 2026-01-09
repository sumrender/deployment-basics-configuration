output "master_public_ip" {
  description = "Public IP address of the master node"
  value       = aws_instance.k3s_master.public_ip
}

output "master_private_ip" {
  description = "Private IP address of the master node"
  value       = aws_instance.k3s_master.private_ip
}

output "master_ssh_command" {
  description = "SSH command to connect to the master node"
  value       = "ssh -i ../prod/ec2-key.pem ubuntu@${aws_instance.k3s_master.public_ip}"
}

output "worker_asg_name" {
  description = "Name of the Auto Scaling Group for worker nodes"
  value       = aws_autoscaling_group.k3s_workers.name
}

output "worker_asg_arn" {
  description = "ARN of the Auto Scaling Group for worker nodes"
  value       = aws_autoscaling_group.k3s_workers.arn
}

output "app_url" {
  description = "URL to access the application"
  value       = "http://${aws_instance.k3s_master.public_ip}/"
}

output "argocd_url" {
  description = "URL to access ArgoCD UI"
  value       = "http://${aws_instance.k3s_master.public_ip}:30033"
}

output "k3s_token_parameter_name" {
  description = "Parameter Store name for k3s server token"
  value       = var.k3s_server_token_parameter_name
}

output "k3s_master_ip_parameter_name" {
  description = "Parameter Store name for k3s master IP"
  value       = var.k3s_master_ip_parameter_name
}

