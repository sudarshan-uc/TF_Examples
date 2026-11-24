terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Not 3.x: restapi 3.0.0 never notices objects deleted or changed outside
    # Terraform (github.com/Mastercard/terraform-provider-restapi/issues/377).
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 2.0.1"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  # State holds connection passwords, secret variables and a short-lived API
  # token. Use an encrypted backend with restricted access, separate from the
  # state of the stack that installs Airflow.
  # backend "s3" {
  #   bucket       = "CHANGE-ME-terraform-state"
  #   key          = "airflow/prod/airflow-config.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
