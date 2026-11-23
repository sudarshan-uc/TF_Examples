variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources. Lowercase letters, digits, hyphens; max 24 chars."
  type        = string
  default     = "airflow-dev"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- networking

variable "vpc_id" {
  description = "Existing VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "At least 2 private subnets in different AZs. Used for EC2, EFS and RDS."
  type        = list(string)
}

variable "alb_subnet_ids" {
  description = "At least 2 subnets in different AZs for the load balancer."
  type        = list(string)
}

variable "alb_internal" {
  description = "true = internal load balancer (reachable only from your network)."
  type        = bool
  default     = true
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to open the Airflow UI through the load balancer."
  type        = list(string)
}

variable "certificate_arn" {
  description = "Optional ACM certificate ARN. If set, the load balancer serves HTTPS on 443 and redirects 80 to 443."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Optional Route 53 zone ID for a friendly URL (used with hostname)."
  type        = string
  default     = null
}

variable "hostname" {
  description = "Optional hostname for the Airflow UI, e.g. airflow-dev.example.com."
  type        = string
  default     = null
}

# ---------------------------------------------------------------- EC2

variable "instance_type" {
  description = "EC2 instance type. Tasks run on this VM (LocalExecutor)."
  type        = string
  default     = "m7i.xlarge"
}

variable "ami_id" {
  description = "Optional AMI ID. Defaults to the latest Amazon Linux 2023 (x86_64)."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root disk size (holds the container images)."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------- RDS

variable "db_engine_version" {
  description = "PostgreSQL major version (Astro Runtime 3.4 supports 14-18)."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage_gb" {
  description = "RDS storage in GB."
  type        = number
  default     = 50
}

variable "db_deletion_protection" {
  description = "Block deletion of the database. Set to false before terraform destroy."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- Airflow

variable "runtime_image" {
  description = "Astro Runtime image, used only when dag_repo_url is empty (starter project). With a repo, the repo's Dockerfile decides the image."
  type        = string
  default     = "quay.io/astronomer/astro-runtime:3.4-1-chainguard"
}

variable "dag_repo_url" {
  description = "HTTPS URL of the Astro project repo (Dockerfile, requirements.txt, packages.txt, dags/). Leave empty to start with a starter project."
  type        = string
  default     = ""
}

variable "dag_repo_branch" {
  description = "Branch to check out."
  type        = string
  default     = "main"
}

variable "airflow_admin_username" {
  description = "Airflow UI username."
  type        = string
  default     = "admin"
}

variable "deploy_version" {
  description = "Optional. Set to any value (e.g. \"1\") to run airflow-deploy on the VM through AWS Systems Manager; change it to run again. null = disabled."
  type        = string
  default     = null
}
