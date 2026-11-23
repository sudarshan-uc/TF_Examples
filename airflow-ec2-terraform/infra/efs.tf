# EFS is mounted at /opt/airflow on the EC2 instance.
# It holds the DAG repo checkout, task logs and the UI password file,
# so they survive if the instance is replaced.

resource "aws_efs_file_system" "airflow" {
  creation_token  = var.name
  encrypted       = true
  throughput_mode = "elastic"

  tags = {
    Name = var.name
  }
}

resource "aws_efs_mount_target" "airflow" {
  for_each = toset(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.airflow.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}
