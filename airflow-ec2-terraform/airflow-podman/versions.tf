terraform {
  # startswith/strcontains and terraform_data need 1.5.
  required_version = ">= 1.5.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }

  # Keep state in an encrypted, access-controlled backend: it holds the
  # generated passwords, Fernet key and JWT secret.
  # backend "s3" {
  #   bucket       = "CHANGE-ME"
  #   key          = "airflow/poc/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
