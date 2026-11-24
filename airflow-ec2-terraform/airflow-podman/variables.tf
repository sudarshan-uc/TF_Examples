# ------------------------------------------------------------------ hosts

variable "hosts" {
  description = <<-EOT
    Existing VMs, keyed by a short name. Terraform reaches each one over SSH.
      address    SSH address (IP or DNS).
      port       SSH port.
      user       SSH user; overrides ssh.user.
      host_key   Host public key to verify (recommended). Unset = not verified.
      private_ip Address the other hosts use to reach this one. Defaults to address.
      roles      Components on this host: api-server, scheduler, dag-processor,
                 triggerer, worker, postgres, redis. Leave unset on a single host
                 to run everything there. Required on every host when there is more than one.
      worker_queues / worker_concurrency  Celery worker settings for this host.
  EOT
  type = map(object({
    address            = string
    port               = optional(number, 22)
    user               = optional(string)
    host_key           = optional(string)
    private_ip         = optional(string)
    roles              = optional(list(string))
    worker_queues      = optional(list(string), ["default"])
    worker_concurrency = optional(number, 16)
  }))

  validation {
    condition     = length(var.hosts) > 0
    error_message = "Define at least one host."
  }
  validation {
    condition = alltrue(flatten([
      for h in var.hosts : [
        for r in coalesce(h.roles, []) :
        contains(["api-server", "scheduler", "dag-processor", "triggerer", "worker", "postgres", "redis"], r)
      ]
    ]))
    error_message = "Valid roles: api-server, scheduler, dag-processor, triggerer, worker, postgres, redis."
  }
  validation {
    condition     = length(var.hosts) == 1 || alltrue([for h in var.hosts : h.roles != null])
    error_message = "With more than one host, set roles on every host."
  }
}

variable "ssh" {
  description = "SSH settings shared by all hosts. private_key_path = null uses the SSH agent."
  type = object({
    user                     = optional(string, "ec2-user")
    private_key_path         = optional(string)
    timeout                  = optional(string, "5m")
    bastion_host             = optional(string)
    bastion_port             = optional(number, 22)
    bastion_user             = optional(string)
    bastion_private_key_path = optional(string)
  })
  default = {}
}

variable "install_podman" {
  description = "Install podman with dnf or apt-get when it is missing. Off by default: the VM image should already have podman 4.6+."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------ image and DAGs

variable "project_dir" {
  description = <<-EOT
    Local path to an Astro project (Dockerfile, requirements.txt, packages.txt, dags/).
    The project is uploaded to each Airflow host and built there with podman.
    dags/ is synced to the hosts and mounted, so DAG-only changes don't rebuild the image.
    Set exactly one of project_dir or image.
  EOT
  type        = string
  default     = null
}

variable "image" {
  description = "Prebuilt Airflow image to pull instead of building project_dir, e.g. registry.example.com/airflow/runtime:3.4-1-chainguard-1. Use an immutable tag."
  type        = string
  default     = null
}

variable "dags_dir" {
  description = "With image: optional local DAG folder to sync and mount. Unset = the DAGs baked into the image are used."
  type        = string
  default     = null
}

variable "registry_auth" {
  description = "Credentials for private registries, keyed by registry host (e.g. \"artifactory.example.com\"). Written to /etc/airflow/registry-auth.json and used for pulls and builds."
  type = map(object({
    username = string
    password = string
  }))
  default   = {}
  sensitive = true
}

variable "build_netrc" {
  description = "Optional .netrc content passed to the image build as the 'netrc' secret, for a private PyPI index. Point pip at it with an --index-url line in requirements.txt."
  type        = string
  default     = null
  sensitive   = true
}

# ------------------------------------------------------------------ Airflow

variable "executor" {
  description = "LocalExecutor (tasks run in the scheduler container) or CeleryExecutor (tasks run on worker hosts)."
  type        = string
  default     = "LocalExecutor"

  validation {
    condition     = contains(["LocalExecutor", "CeleryExecutor"], var.executor)
    error_message = "executor must be LocalExecutor or CeleryExecutor."
  }
}

variable "sql_alchemy_conn" {
  description = <<-EOT
    Airflow metadata DB, e.g. postgresql+psycopg2://airflow:<url-encoded password>@db.example.com:5432/airflow
    Unset = run Postgres in a container on the host that has the postgres role (dev and test only).
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "celery_broker_url" {
  description = "CeleryExecutor broker, e.g. redis://:password@redis.example.com:6379/0. Unset = run Redis on the host with the redis role."
  type        = string
  default     = null
  sensitive   = true
}

variable "celery_result_backend" {
  description = "CeleryExecutor result backend. Unset = db+<sql_alchemy_conn>."
  type        = string
  default     = null
  sensitive   = true
}

variable "fernet_key" {
  description = "Fernet key. Set it when you reuse a database that already has encrypted connections. Unset = generated."
  type        = string
  default     = null
  sensitive   = true
}

variable "users" {
  description = "Airflow UI/API users for SimpleAuthManager: username => role (viewer, user, op, admin). Passwords are generated; see output user_passwords."
  type        = map(string)
  default     = { admin = "admin" }

  validation {
    condition     = length(var.users) > 0 && alltrue([for r in values(var.users) : contains(["viewer", "user", "op", "admin"], r)])
    error_message = "users must map names to one of: viewer, user, op, admin."
  }
}

variable "api_server_port" {
  description = "Port the API server (UI) listens on, on every api-server host."
  type        = number
  default     = 8080
}

variable "api_server_workers" {
  description = "API server worker processes."
  type        = number
  default     = 2
}

variable "api_base_url" {
  description = "Public URL of the UI when it sits behind a load balancer, e.g. https://airflow.example.com. Sets [api] base_url."
  type        = string
  default     = null
}

variable "execution_api_server_url" {
  description = "URL task processes use to reach the Execution API. Unset = the local api-server when the host has one, otherwise the first api-server host."
  type        = string
  default     = null
}

variable "airflow_env" {
  description = "Extra AIRFLOW__* (or other) environment variables for every Airflow container. Applied last, so they override the defaults."
  type        = map(string)
  default     = {}
}

variable "airflow_secret_env" {
  description = "Like airflow_env, for values that must stay out of plan output."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# ------------------------------------------------------------------ bundled Postgres and Redis (dev/test)

variable "postgres_image" {
  description = "Image for the bundled Postgres (only used when sql_alchemy_conn is unset)."
  type        = string
  default     = "docker.io/library/postgres:16"
}

variable "redis_image" {
  description = "Image for the bundled Redis (only used with CeleryExecutor when celery_broker_url is unset)."
  type        = string
  default     = "docker.io/library/redis:7.2"
}

# ------------------------------------------------------------------ host layout

variable "base_dir" {
  description = "Data directory on each host: dags/, logs/, config/, and postgres/ or redis/ for bundled services."
  type        = string
  default     = "/opt/airflow"

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+[A-Za-z0-9._-]$", var.base_dir)) && !contains(["/", "/etc", "/usr", "/var", "/opt", "/home", "/root", "/tmp", "/bin", "/sbin", "/lib", "/boot"], var.base_dir)
    error_message = "base_dir must be an absolute path below a top-level directory, e.g. /opt/airflow."
  }
}

variable "staging_dir" {
  description = "Where Terraform uploads files on each host before applying them. Owned by the SSH user."
  type        = string
  default     = "/var/tmp/airflow-terraform"

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+[A-Za-z0-9._-]$", var.staging_dir)) && length(split("/", var.staging_dir)) > 2
    error_message = "staging_dir must be an absolute path at least two levels deep."
  }
}

variable "purge_data_on_destroy" {
  description = "On destroy, also delete base_dir (DAGs, logs and any bundled Postgres/Redis data). Off by default."
  type        = bool
  default     = false
}
