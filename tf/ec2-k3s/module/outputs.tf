output "default_vpc_id" {
  description = "ID of the default VPC"
  value       = data.aws_vpc.default.id
}

output "default_subnet_id" {
  description = "ID of the first default subnet"
  value       = data.aws_subnet.default.id
}

output "ubuntu_ami_id" {
  description = "ID of the latest Ubuntu 22.04 LTS AMI"
  value       = data.aws_ami.ubuntu.id
}

output "ec2_key_pair_name" {
  description = "Name of the AWS key pair"
  value       = aws_key_pair.ec2_key_pair.key_name
}

output "private_key_file_path" {
  description = "Path to the private key file"
  value       = local_file.private_key.filename
}

