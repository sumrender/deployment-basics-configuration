output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = module.ec2_k3s.instance_public_ip
}

output "app_url" {
  description = "URL to access the application"
  value       = module.ec2_k3s.app_url
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = module.ec2_k3s.ssh_command
}

output "kubectl_command" {
  description = "Command to access kubectl on the instance (via SSH)"
  value       = module.ec2_k3s.kubectl_command
}