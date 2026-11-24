variable "airflow_url" {
  description = "Airflow base URL, for example https://airflow.example.internal. The API is reached at <url>/api/v2."
  type        = string

  validation {
    condition     = can(regex("^https?://", var.airflow_url))
    error_message = "airflow_url must start with http:// or https://."
  }
}

variable "airflow_username" {
  description = "Airflow user for the API. Set its password in the AIRFLOW_PASSWORD environment variable, or a token in AIRFLOW_API_TOKEN."
  type        = string
  default     = "admin"
}

variable "ca_file" {
  description = "PEM bundle that signs the Airflow HTTPS certificate, when it is not in the system trust store."
  type        = string
  default     = null
}

variable "connections" {
  description = <<-EOT
    Airflow connections, keyed by connection_id. Everything here shows in plans.
    Put passwords and secret extra keys in connection_secrets instead.
    extra is a JSON string: extra = jsonencode({ region_name = "us-east-1" }).
    A field you remove is cleared in Airflow on the next apply.
  EOT
  type = map(object({
    conn_type   = string
    description = optional(string)
    host        = optional(string)
    port        = optional(number)
    login       = optional(string)
    schema      = optional(string)
    extra       = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for c in values(var.connections) : c.extra == null || can(tomap(jsondecode(c.extra)))])
    error_message = "connections[*].extra must be a JSON object string, for example jsonencode({ region_name = \"us-east-1\" })."
  }
}

variable "connection_secrets" {
  description = <<-EOT
    Secret parts of connections, keyed by connection_id (must also be in connections).
    password is the connection password. extra is a JSON object string whose keys are
    merged over connections[id].extra.
  EOT
  type = map(object({
    password = optional(string)
    extra    = optional(string)
  }))
  default   = {}
  sensitive = true
}

variable "airflow_variables" {
  description = "Airflow variables, key = value. Values are strings; use jsonencode() for JSON values. Shown in plans."
  type        = map(string)
  default     = {}
}

variable "secret_variables" {
  description = "Airflow variables whose values must not show in plans, key = value."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "pools" {
  description = "Airflow pools, keyed by name. Use default_pool_slots for default_pool."
  type = map(object({
    slots            = number
    description      = optional(string, "")
    include_deferred = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = !contains(keys(var.pools), "default_pool")
    error_message = "default_pool cannot be created or deleted. Set default_pool_slots instead."
  }
}

variable "default_pool_slots" {
  description = "Slots for default_pool. null leaves it alone. On destroy it is set back to 128."
  type        = number
  default     = null
}

variable "extra_sensitive_names" {
  description = "Names you added to Airflow's [core] sensitive_var_conn_names. Airflow masks matching values in API responses, so drift on them can't be checked."
  type        = list(string)
  default     = []
}
