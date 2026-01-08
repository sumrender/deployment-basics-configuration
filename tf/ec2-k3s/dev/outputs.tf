output "app_url" {
  description = "URL to access the application"
  value       = "http://${aws_instance.k3s_cluster.public_ip}/"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ec2-key.pem ubuntu@${aws_instance.k3s_cluster.public_ip}"
}

