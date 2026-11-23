output "airflow_url" {
  description = "Airflow UI."
  value       = local.base_url
}

output "airflow_admin_username" {
  value = var.airflow_admin_username
}

output "airflow_admin_password" {
  description = "Show with: terraform output -raw airflow_admin_password"
  value       = random_password.admin.result
  sensitive   = true
}

output "instance_id" {
  value = aws_instance.airflow.id
}

output "connect_command" {
  description = "Open a shell on the instance."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.airflow.id}"
}

output "rds_endpoint" {
  value = aws_db_instance.airflow.address
}

output "efs_id" {
  value = aws_efs_file_system.airflow.id
}

output "alb_dns_name" {
  value = aws_lb.airflow.dns_name
}
