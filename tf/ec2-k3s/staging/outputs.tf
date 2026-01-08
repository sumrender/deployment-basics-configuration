output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.k3s_cluster.public_ip
}

output "app_url" {
  description = "URL to access the application"
  value       = "http://${aws_instance.k3s_cluster.public_ip}/"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ec2-key.pem ubuntu@${aws_instance.k3s_cluster.public_ip}"
}

output "kubectl_command" {
  description = "Command to access kubectl on the instance (via SSH)"
  value       = "ssh -i ec2-key.pem ubuntu@${aws_instance.k3s_cluster.public_ip} 'sudo k3s kubectl'"
}

output "log_file_location" {
  description = "Location of the bootstrap log file on the instance"
  value       = "/var/log/bootstrap-k3s-ec2/latest.log (or /tmp/bootstrap-k3s-ec2/latest.log if /var/log is not writable)"
}

output "view_logs_tail" {
  description = "Command to tail the bootstrap log file (follow in real-time)"
  value       = "ssh -i ec2-key.pem ubuntu@${aws_instance.k3s_cluster.public_ip} 'sudo tail -f /var/log/bootstrap-k3s-ec2/latest.log || sudo tail -f /tmp/bootstrap-k3s-ec2/latest.log'"
}

output "view_logs_cat" {
  description = "Command to view the full bootstrap log file"
  value       = "ssh -i ec2-key.pem ubuntu@${aws_instance.k3s_cluster.public_ip} 'sudo cat /var/log/bootstrap-k3s-ec2/latest.log || sudo cat /tmp/bootstrap-k3s-ec2/latest.log'"
}

output "view_logs_less" {
  description = "Command to view the bootstrap log file with less (interactive pager)"
  value       = "ssh -i ec2-key.pem ubuntu@${aws_instance.k3s_cluster.public_ip} 'sudo less /var/log/bootstrap-k3s-ec2/latest.log || sudo less /tmp/bootstrap-k3s-ec2/latest.log'"
}