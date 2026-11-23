data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id   = coalesce(var.ami_id, data.aws_ssm_parameter.al2023.insecure_value)
  https    = var.certificate_arn != null
  host     = coalesce(var.hostname, aws_lb.airflow.dns_name)
  base_url = "${local.https ? "https" : "http"}://${local.host}"
}

# Generated once, kept in Terraform state.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length  = 20
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "random_password" "api_secret_key" {
  length  = 64
  special = false
}

resource "random_bytes" "fernet" {
  length = 32
}
