# Gets an Airflow API token (POST /auth/token) on every plan and apply. The
# password is read from the AIRFLOW_PASSWORD environment variable inside the
# script, so it never appears in the plan or the state. The token does: it is
# valid for [api_auth] jwt_expiration_time (24 hours by default).
data "external" "airflow_token" {
  program = ["python3", "${path.module}/scripts/get_airflow_token.py"]

  query = {
    airflow_url = trimsuffix(var.airflow_url, "/")
    username    = var.airflow_username
    ca_file     = var.ca_file == null ? "" : pathexpand(var.ca_file)
  }
}

provider "restapi" {
  uri                  = trimsuffix(var.airflow_url, "/")
  root_ca_file         = var.ca_file == null ? null : pathexpand(var.ca_file)
  write_returns_object = true
  timeout              = 60

  headers = {
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer ${data.external.airflow_token.result.access_token}"
  }
}
