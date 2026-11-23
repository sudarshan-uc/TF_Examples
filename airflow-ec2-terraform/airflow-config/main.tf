# Get a short-lived Airflow API token (POST /auth/token) at every plan/apply.
# The external data source runs the script on the machine running Terraform.
data "external" "airflow_token" {
  program = ["python3", "${path.module}/scripts/get_airflow_token.py"]

  query = {
    airflow_url = var.airflow_url
    username    = var.airflow_username
    password    = var.airflow_password
  }
}

# Talks to the Airflow 3 REST API (/api/v2) through the load balancer.
provider "restapi" {
  uri                  = trimsuffix(var.airflow_url, "/")
  bearer_token         = data.external.airflow_token.result.access_token
  write_returns_object = true

  headers = {
    "Content-Type" = "application/json"
  }
}
