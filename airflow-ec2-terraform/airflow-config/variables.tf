variable "airflow_url" {
  description = "Airflow URL from the infra stack (terraform output airflow_url)."
  type        = string
}

variable "airflow_username" {
  description = "Airflow UI/API user."
  type        = string
  default     = "admin"
}

variable "airflow_password" {
  description = "Airflow password (terraform output -raw airflow_admin_password in the infra stack)."
  type        = string
  sensitive   = true
}

variable "connections" {
  description = "Airflow connections, keyed by connection_id."
  type = map(object({
    conn_type   = string
    description = optional(string)
    host        = optional(string)
    port        = optional(number)
    login       = optional(string)
    password    = optional(string)
    schema      = optional(string)
    extra       = optional(string) # JSON string, e.g. jsonencode({ region_name = "us-east-1" })
  }))
  default   = {}
  sensitive = true
}

variable "airflow_variables" {
  description = "Airflow variables (key = value)."
  type        = map(string)
  default     = {}
}

variable "pools" {
  description = "Airflow pools, keyed by pool name. Do not include default_pool (it already exists)."
  type = map(object({
    slots            = number
    description      = optional(string, "")
    include_deferred = optional(bool, false)
  }))
  default = {}
}
