terraform {
  required_version = ">= 1.5.0"

  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  # Use a separate state from the infra stack. Uncomment and fill in.
  # backend "s3" {
  #   bucket       = "CHANGE-ME-terraform-state"
  #   key          = "airflow/dev/airflow-config.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}
