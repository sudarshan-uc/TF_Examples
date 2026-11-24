locals {
  airflow_components = ["api-server", "scheduler", "dag-processor", "triggerer", "worker"]
  service_roles      = ["postgres", "redis"]

  celery = var.executor == "CeleryExecutor"
  # Only whether these are set drives placement, not their values.
  bundled_db     = nonsensitive(var.sql_alchemy_conn == null)
  bundled_broker = local.celery && nonsensitive(var.celery_broker_url == null)
  multi_host     = length(var.hosts) > 1

  # ---------------------------------------------------------------- placement

  default_roles = concat(
    ["api-server", "scheduler", "dag-processor", "triggerer"],
    local.celery ? ["worker"] : [],
    local.bundled_broker ? ["redis"] : [],
    local.bundled_db ? ["postgres"] : [],
  )

  roles = { for k, h in var.hosts : k => distinct(h.roles != null ? h.roles : local.default_roles) }

  hosts_with = {
    for r in concat(local.airflow_components, local.service_roles) :
    r => sort([for k, rs in local.roles : k if contains(rs, r)])
  }

  airflow_hosts = toset([
    for k, rs in local.roles : k if length(setintersection(toset(rs), toset(local.airflow_components))) > 0
  ])

  # db migrate runs once, on the first scheduler host, before any component (re)starts.
  migration_host = try(local.hosts_with["scheduler"][0], null)
  postgres_host  = try(local.hosts_with["postgres"][0], null)
  redis_host     = try(local.hosts_with["redis"][0], null)

  ip = { for k, h in var.hosts : k => coalesce(h.private_ip, h.address) }

  # How host `from` reaches host `to`: loopback for itself, private IP otherwise.
  addr = { for from in keys(var.hosts) : from => { for to in keys(var.hosts) : to => from == to ? "127.0.0.1" : local.ip[to] } }

  # ---------------------------------------------------------------- image and DAGs

  build_mode = var.project_dir != null

  # Files that don't affect the build or the DAGs. They are still uploaded.
  ignored_prefixes = [".git/", ".astro/", ".venv/", "venv/", "logs/"]

  project_files = local.build_mode ? sort([
    for f in fileset(var.project_dir, "**") : f
    if !anytrue([for p in local.ignored_prefixes : startswith(f, p)]) && !strcontains(f, "__pycache__") && !endswith(f, ".pyc")
  ]) : []

  build_files = [for f in local.project_files : f if !startswith(f, "dags/")]
  build_hash  = sha256(join("\n", [for f in local.build_files : "${f}=${filesha256("${var.project_dir}/${f}")}"]))

  # A built image is tagged with the hash of the project files outside dags/,
  # so a requirements/packages/Dockerfile change builds and rolls out a new image.
  airflow_image = local.build_mode ? "localhost/airflow-runtime:${substr(local.build_hash, 0, 16)}" : var.image

  mount_dags = local.build_mode || var.dags_dir != null
  dags_root  = local.build_mode ? "${var.project_dir}/dags" : var.dags_dir
  dags_files = local.mount_dags ? sort([
    for f in fileset(local.dags_root, "**") : f
    if !strcontains(f, "__pycache__") && !endswith(f, ".pyc")
  ]) : []
  dags_hash = sha256(join("\n", [for f in local.dags_files : "${f}=${filesha256("${local.dags_root}/${f}")}"]))

  # What gets uploaded to <staging_dir>/payload on each host.
  payload_dir = {
    for k in keys(var.hosts) : k => (
      contains(local.airflow_hosts, k) && local.build_mode ? var.project_dir :
      contains(local.airflow_hosts, k) && var.dags_dir != null ? var.dags_dir :
      "${path.module}/files/empty"
    )
  }
  payload_dags_src = "${var.staging_dir}/payload${local.build_mode ? "/dags" : ""}"

  # ---------------------------------------------------------------- Airflow configuration

  container_home = "/usr/local/airflow"
  passwords_path = "${local.container_home}/config/simple_auth_manager_passwords.json"

  db_conn = {
    for h in keys(var.hosts) : h => (
      local.bundled_db
      ? "postgresql+psycopg2://airflow:${random_password.postgres.result}@${try(local.addr[h][local.postgres_host], "postgres-host-missing")}:5432/airflow"
      : var.sql_alchemy_conn
    )
  }

  broker_url = {
    for h in keys(var.hosts) : h => (
      local.bundled_broker
      ? "redis://:${random_password.redis.result}@${try(local.addr[h][local.redis_host], "redis-host-missing")}:6379/0"
      : var.celery_broker_url
    )
  }

  execution_api_url = {
    for h in keys(var.hosts) : h => (
      var.execution_api_server_url != null ? var.execution_api_server_url :
      contains(local.roles[h], "api-server") ? "http://127.0.0.1:${var.api_server_port}/execution/" :
      "http://${try(local.ip[local.hosts_with["api-server"][0]], "api-server-host-missing")}:${var.api_server_port}/execution/"
    )
  }

  airflow_env = {
    for h in local.airflow_hosts : h => merge(
      {
        AIRFLOW__CORE__EXECUTOR                           = var.executor
        AIRFLOW__CORE__LOAD_EXAMPLES                      = "False"
        AIRFLOW__DATABASE__SQL_ALCHEMY_CONN               = local.db_conn[h]
        AIRFLOW__CORE__FERNET_KEY                         = local.fernet_key
        AIRFLOW__API_AUTH__JWT_SECRET                     = random_password.jwt_secret.result
        AIRFLOW__API__SECRET_KEY                          = random_password.api_secret_key.result
        AIRFLOW__CORE__EXECUTION_API_SERVER_URL           = local.execution_api_url[h]
        AIRFLOW__CORE__AUTH_MANAGER                       = "airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager"
        AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS          = join(",", [for u in sort(keys(var.users)) : "${u}:${var.users[u]}"])
        AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE = local.passwords_path
      },
      local.celery ? {
        AIRFLOW__CELERY__BROKER_URL     = local.broker_url[h]
        AIRFLOW__CELERY__RESULT_BACKEND = var.celery_result_backend != null ? var.celery_result_backend : "db+${local.db_conn[h]}"
      } : {},
      # Hosts register themselves (jobs, task log URLs) by IP so the others can reach them.
      local.multi_host ? { AIRFLOW__CORE__HOSTNAME_CALLABLE = "airflow.utils.net.get_host_ip_address" } : {},
      var.api_base_url != null ? { AIRFLOW__API__BASE_URL = var.api_base_url } : {},
      var.airflow_env,
      var.airflow_secret_env,
    )
  }

  env_file = { for h, e in local.airflow_env : h => join("", [for k in sort(keys(e)) : "${k}=${e[k]}\n"]) }

  postgres_env = join("", [
    "POSTGRES_USER=airflow\n",
    "POSTGRES_PASSWORD=${random_password.postgres.result}\n",
    "POSTGRES_DB=airflow\n",
    "PGDATA=/var/lib/postgresql/data/pgdata\n",
  ])

  redis_conf = join("", [
    "bind ${local.multi_host ? "0.0.0.0" : "127.0.0.1"}\n",
    "port 6379\n",
    "requirepass ${random_password.redis.result}\n",
    "appendonly yes\n",
    "dir /data\n",
  ])

  # ---------------------------------------------------------------- quadlet units

  airflow_volumes = concat(
    local.mount_dags ? ["${var.base_dir}/dags:${local.container_home}/dags:ro,z"] : [],
    [
      "${var.base_dir}/logs:${local.container_home}/logs:z",
      "${var.base_dir}/config:${local.container_home}/config:z",
    ],
  )

  airflow_exec = {
    "api-server"    = "airflow api-server --port ${var.api_server_port} --workers ${var.api_server_workers}"
    "scheduler"     = "airflow scheduler"
    "dag-processor" = "airflow dag-processor"
    "triggerer"     = "airflow triggerer"
    "db-migrate"    = "airflow db migrate"
  }

  airflow_health = {
    "api-server"    = "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.api_server_port}/api/v2/monitor/health', timeout=20)\""
    "scheduler"     = "airflow jobs check --job-type SchedulerJob --local"
    "dag-processor" = "airflow jobs check --job-type DagProcessorJob --local"
    "triggerer"     = "airflow jobs check --job-type TriggererJob --local"
  }

  # Units on each host that the airflow and migrate phases own.
  airflow_units_on = {
    for h, rs in local.roles : h => concat(
      [for c in local.airflow_components : c if contains(rs, c)],
      h == local.migration_host ? ["db-migrate"] : [],
    )
  }

  local_service_deps = {
    for h, rs in local.roles : h => concat(
      contains(rs, "postgres") ? ["airflow-postgres.service"] : [],
      contains(rs, "redis") ? ["airflow-redis.service"] : [],
    )
  }

  unit_template = "${path.module}/templates/unit.container.tftpl"

  units = {
    for h, rs in local.roles : h => merge(
      {
        for c in local.airflow_units_on[h] : c => templatefile(local.unit_template, {
          name      = "airflow-${c}"
          component = c
          image     = local.airflow_image
          exec      = c == "worker" ? "airflow celery worker --queues ${join(",", var.hosts[h].worker_queues)} --concurrency ${var.hosts[h].worker_concurrency}" : local.airflow_exec[c]
          env_files = ["/etc/airflow/airflow.env"]
          volumes   = local.airflow_volumes
          secrets   = []
          # The VM hostname often resolves only through the host's NSS (nss-myhostname)
          # or not at all inside the container. Pin it to private_ip so
          # hostname_callable returns the address the other hosts use for log fetches.
          add_hosts   = local.multi_host ? ["%H:${local.ip[h]}"] : []
          health_cmd  = lookup(local.airflow_health, c, "")
          after       = concat(local.local_service_deps[h], c != "db-migrate" && h == local.migration_host ? ["airflow-db-migrate.service"] : [])
          oneshot     = c == "db-migrate"
          config_hash = sha256(join("\n", [local.env_file[h], c == "api-server" ? local.passwords_json : ""]))
        })
      },
      contains(rs, "postgres") ? {
        postgres = templatefile(local.unit_template, {
          name        = "airflow-postgres"
          component   = "postgres"
          image       = var.postgres_image
          exec        = "postgres -c listen_addresses=${local.multi_host ? "*" : "127.0.0.1"}"
          env_files   = ["/etc/airflow/postgres.env"]
          volumes     = ["${var.base_dir}/postgres:/var/lib/postgresql/data:Z"]
          add_hosts   = []
          secrets     = []
          health_cmd  = "pg_isready -h 127.0.0.1 -U airflow -d airflow"
          after       = []
          oneshot     = false
          config_hash = sha256(local.postgres_env)
        })
      } : {},
      contains(rs, "redis") ? {
        redis = templatefile(local.unit_template, {
          name        = "airflow-redis"
          component   = "redis"
          image       = var.redis_image
          exec        = "redis-server /run/secrets/redis.conf"
          env_files   = []
          volumes     = ["${var.base_dir}/redis:/data:Z"]
          add_hosts   = []
          secrets     = ["airflow-redis-conf,type=mount,target=redis.conf,uid=999,gid=999,mode=0400"]
          health_cmd  = "sh -c \"redis-cli -h 127.0.0.1 ping 2>&1 | grep -qE 'PONG|NOAUTH'\""
          after       = []
          oneshot     = false
          config_hash = sha256(local.redis_conf)
        })
      } : {},
    )
  }

  # ---------------------------------------------------------------- per-phase scripts

  script_defaults = {
    base_dir       = var.base_dir
    stage_dir      = var.staging_dir
    install_podman = var.install_podman
    image          = local.airflow_image
    build_mode     = local.build_mode
    airflow_host   = false
    roles          = []
    pull_images    = []
    root_files     = []
    passwords_b64  = ""
    authfile_b64   = ""
    netrc_b64      = ""
    redis_conf_b64 = ""
    mount_dags     = false
    dags_src       = local.payload_dags_src
    dags_hash      = local.dags_hash
    units          = []
    start          = []
    prune          = []
    wait_api       = false
    api_port       = var.api_server_port
    prune_images   = false
  }

  base_script = {
    for h, rs in local.roles : h => templatefile("${path.module}/templates/apply.sh.tftpl", merge(local.script_defaults, {
      phase        = "base"
      airflow_host = contains(local.airflow_hosts, h)
      roles        = rs
      pull_images = concat(
        contains(local.airflow_hosts, h) && !local.build_mode ? [local.airflow_image] : [],
        contains(rs, "postgres") ? [var.postgres_image] : [],
        contains(rs, "redis") ? [var.redis_image] : [],
      )
      root_files = concat(
        contains(local.airflow_hosts, h) ? [{ path = "/etc/airflow/airflow.env", mode = "0600", b64 = base64encode(local.env_file[h]) }] : [],
        contains(rs, "postgres") ? [{ path = "/etc/airflow/postgres.env", mode = "0600", b64 = base64encode(local.postgres_env) }] : [],
      )
      passwords_b64  = contains(local.airflow_hosts, h) ? base64encode(local.passwords_json) : ""
      authfile_b64   = local.registry_auth_json == "" ? "" : base64encode(local.registry_auth_json)
      netrc_b64      = var.build_netrc == null ? "" : base64encode(var.build_netrc)
      redis_conf_b64 = contains(rs, "redis") ? base64encode(local.redis_conf) : ""
      mount_dags     = contains(local.airflow_hosts, h) && local.mount_dags
      units          = [for c in local.service_roles : { name = "airflow-${c}", b64 = base64encode(local.units[h][c]) } if contains(rs, c)]
      start          = [for c in local.service_roles : "airflow-${c}" if contains(rs, c)]
      # Service roles that moved away, plus every Airflow unit if this host has none left.
      prune = concat(
        [for c in local.service_roles : "airflow-${c}" if !contains(rs, c)],
        contains(local.airflow_hosts, h) ? [] : [for c in concat(local.airflow_components, ["db-migrate"]) : "airflow-${c}"],
      )
    }))
  }

  migrate_script = local.migration_host == null ? "" : templatefile("${path.module}/templates/apply.sh.tftpl", merge(local.script_defaults, {
    phase = "migrate"
    units = [{ name = "airflow-db-migrate", b64 = base64encode(local.units[local.migration_host]["db-migrate"]) }]
    start = ["airflow-db-migrate"]
  }))

  airflow_script = {
    for h in local.airflow_hosts : h => templatefile("${path.module}/templates/apply.sh.tftpl", merge(local.script_defaults, {
      phase        = "airflow"
      airflow_host = true
      roles        = local.roles[h]
      units        = [for c in local.airflow_components : { name = "airflow-${c}", b64 = base64encode(local.units[h][c]) } if contains(local.roles[h], c)]
      start        = [for c in local.airflow_components : "airflow-${c}" if contains(local.roles[h], c)]
      prune = concat(
        [for c in local.airflow_components : "airflow-${c}" if !contains(local.roles[h], c)],
        h == local.migration_host ? [] : ["airflow-db-migrate"],
      )
      wait_api     = contains(local.roles[h], "api-server")
      prune_images = local.build_mode
    }))
  }

  teardown_script = templatefile("${path.module}/templates/teardown.sh.tftpl", {
    base_dir  = var.base_dir
    stage_dir = var.staging_dir
    purge     = var.purge_data_on_destroy
  })

  # ---------------------------------------------------------------- SSH

  conn = {
    for k, h in var.hosts : k => {
      host                     = h.address
      port                     = h.port
      user                     = coalesce(h.user, var.ssh.user)
      host_key                 = h.host_key
      private_key_path         = var.ssh.private_key_path
      timeout                  = var.ssh.timeout
      bastion_host             = var.ssh.bastion_host
      bastion_port             = var.ssh.bastion_port
      bastion_user             = var.ssh.bastion_user
      bastion_private_key_path = var.ssh.bastion_private_key_path
      sudo                     = coalesce(h.user, var.ssh.user) == "root" ? "" : "sudo -n "
    }
  }
}
