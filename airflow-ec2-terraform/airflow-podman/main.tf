# Order on every apply:
#   teardown[host]  (no-op on create; removes everything on destroy)
#   base[host]      files, images, DAGs, bundled Postgres/Redis    - all hosts
#   migrate         airflow db migrate (oneshot unit)              - first scheduler host
#   airflow[host]   api-server, scheduler, dag-processor, ...      - Airflow hosts
#
# Each step re-runs only when its rendered script (or the uploaded files) changes.
# On the host, units are rewritten only when their content changes, and only
# changed or stopped units are restarted.

resource "terraform_data" "teardown" {
  for_each = var.hosts

  # input is updated in place (never replaced), so changing these values does
  # not trigger the destroy-time teardown.
  input = {
    host                     = local.conn[each.key].host
    port                     = local.conn[each.key].port
    user                     = local.conn[each.key].user
    host_key                 = local.conn[each.key].host_key
    private_key_path         = local.conn[each.key].private_key_path
    timeout                  = local.conn[each.key].timeout
    bastion_host             = local.conn[each.key].bastion_host
    bastion_port             = local.conn[each.key].bastion_port
    bastion_user             = local.conn[each.key].bastion_user
    bastion_private_key_path = local.conn[each.key].bastion_private_key_path
    sudo                     = local.conn[each.key].sudo
    stage_dir                = var.staging_dir
    script                   = local.teardown_script
  }

  lifecycle {
    precondition {
      condition     = (var.project_dir == null) != (var.image == null)
      error_message = "Set exactly one of project_dir (build on the hosts) or image (pull a prebuilt image)."
    }
    precondition {
      condition     = var.dags_dir == null || var.image != null
      error_message = "dags_dir is only used with image. With project_dir, DAGs come from <project_dir>/dags."
    }
    precondition {
      condition     = length(local.hosts_with["api-server"]) > 0 && length(local.hosts_with["scheduler"]) > 0 && length(local.hosts_with["dag-processor"]) > 0
      error_message = "Place at least one api-server, scheduler and dag-processor."
    }
    precondition {
      condition     = local.celery ? length(local.hosts_with["worker"]) > 0 : length(local.hosts_with["worker"]) == 0
      error_message = "CeleryExecutor needs at least one worker host; LocalExecutor takes no worker role (tasks run in the scheduler)."
    }
    precondition {
      condition     = length(local.hosts_with["postgres"]) == (local.bundled_db ? 1 : 0)
      error_message = "With sql_alchemy_conn unset, exactly one host needs the postgres role. With sql_alchemy_conn set, none may have it."
    }
    precondition {
      condition     = length(local.hosts_with["redis"]) == (local.bundled_broker ? 1 : 0)
      error_message = "CeleryExecutor with celery_broker_url unset needs exactly one redis host. Otherwise no host may have the redis role."
    }
    precondition {
      condition     = alltrue([for k, v in var.airflow_env : !strcontains(k, "=") && !strcontains(v, "\n")])
      error_message = "airflow_env keys can't contain '=' and values can't contain newlines."
    }
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline     = ["mkdir -p ${self.input.stage_dir} && chmod 700 ${self.input.stage_dir}"]

    connection {
      type                = "ssh"
      host                = self.input.host
      port                = self.input.port
      user                = self.input.user
      host_key            = self.input.host_key
      private_key         = self.input.private_key_path == null ? null : file(self.input.private_key_path)
      agent               = self.input.private_key_path == null
      timeout             = self.input.timeout
      bastion_host        = self.input.bastion_host
      bastion_port        = self.input.bastion_port
      bastion_user        = self.input.bastion_user
      bastion_private_key = self.input.bastion_private_key_path == null ? null : file(self.input.bastion_private_key_path)
    }
  }

  provisioner "file" {
    when        = destroy
    on_failure  = continue
    content     = self.input.script
    destination = "${self.input.stage_dir}/teardown.sh"

    connection {
      type                = "ssh"
      host                = self.input.host
      port                = self.input.port
      user                = self.input.user
      host_key            = self.input.host_key
      private_key         = self.input.private_key_path == null ? null : file(self.input.private_key_path)
      agent               = self.input.private_key_path == null
      timeout             = self.input.timeout
      bastion_host        = self.input.bastion_host
      bastion_port        = self.input.bastion_port
      bastion_user        = self.input.bastion_user
      bastion_private_key = self.input.bastion_private_key_path == null ? null : file(self.input.bastion_private_key_path)
    }
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline     = ["${self.input.sudo}bash ${self.input.stage_dir}/teardown.sh"]

    connection {
      type                = "ssh"
      host                = self.input.host
      port                = self.input.port
      user                = self.input.user
      host_key            = self.input.host_key
      private_key         = self.input.private_key_path == null ? null : file(self.input.private_key_path)
      agent               = self.input.private_key_path == null
      timeout             = self.input.timeout
      bastion_host        = self.input.bastion_host
      bastion_port        = self.input.bastion_port
      bastion_user        = self.input.bastion_user
      bastion_private_key = self.input.bastion_private_key_path == null ? null : file(self.input.bastion_private_key_path)
    }
  }
}

resource "terraform_data" "base" {
  for_each = var.hosts

  triggers_replace = {
    script  = nonsensitive(sha256(local.base_script[each.key]))
    payload = contains(local.airflow_hosts, each.key) ? sha256(join("\n", [local.build_hash, local.dags_hash])) : "none"
  }

  connection {
    type                = "ssh"
    host                = local.conn[each.key].host
    port                = local.conn[each.key].port
    user                = local.conn[each.key].user
    host_key            = local.conn[each.key].host_key
    private_key         = local.conn[each.key].private_key_path == null ? null : file(local.conn[each.key].private_key_path)
    agent               = local.conn[each.key].private_key_path == null
    timeout             = local.conn[each.key].timeout
    bastion_host        = local.conn[each.key].bastion_host
    bastion_port        = local.conn[each.key].bastion_port
    bastion_user        = local.conn[each.key].bastion_user
    bastion_private_key = local.conn[each.key].bastion_private_key_path == null ? null : file(local.conn[each.key].bastion_private_key_path)
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p ${var.staging_dir} && chmod 700 ${var.staging_dir} && rm -rf ${var.staging_dir}/payload && mkdir ${var.staging_dir}/payload"]
  }

  provisioner "file" {
    source      = "${local.payload_dir[each.key]}/"
    destination = "${var.staging_dir}/payload"
  }

  provisioner "file" {
    content     = local.base_script[each.key]
    destination = "${var.staging_dir}/base.sh"
  }

  provisioner "remote-exec" {
    inline = ["${local.conn[each.key].sudo}bash ${var.staging_dir}/base.sh; rc=$?; rm -f ${var.staging_dir}/base.sh; exit $rc"]
  }

  depends_on = [terraform_data.teardown]
}

resource "terraform_data" "migrate" {
  triggers_replace = nonsensitive(sha256(local.migrate_script))

  connection {
    type                = "ssh"
    host                = local.conn[local.migration_host].host
    port                = local.conn[local.migration_host].port
    user                = local.conn[local.migration_host].user
    host_key            = local.conn[local.migration_host].host_key
    private_key         = local.conn[local.migration_host].private_key_path == null ? null : file(local.conn[local.migration_host].private_key_path)
    agent               = local.conn[local.migration_host].private_key_path == null
    timeout             = local.conn[local.migration_host].timeout
    bastion_host        = local.conn[local.migration_host].bastion_host
    bastion_port        = local.conn[local.migration_host].bastion_port
    bastion_user        = local.conn[local.migration_host].bastion_user
    bastion_private_key = local.conn[local.migration_host].bastion_private_key_path == null ? null : file(local.conn[local.migration_host].bastion_private_key_path)
  }

  provisioner "file" {
    content     = local.migrate_script
    destination = "${var.staging_dir}/migrate.sh"
  }

  provisioner "remote-exec" {
    inline = ["${local.conn[local.migration_host].sudo}bash ${var.staging_dir}/migrate.sh; rc=$?; rm -f ${var.staging_dir}/migrate.sh; exit $rc"]
  }

  depends_on = [terraform_data.base]
}

resource "terraform_data" "airflow" {
  for_each = local.airflow_hosts

  triggers_replace = nonsensitive(sha256(local.airflow_script[each.key]))

  connection {
    type                = "ssh"
    host                = local.conn[each.key].host
    port                = local.conn[each.key].port
    user                = local.conn[each.key].user
    host_key            = local.conn[each.key].host_key
    private_key         = local.conn[each.key].private_key_path == null ? null : file(local.conn[each.key].private_key_path)
    agent               = local.conn[each.key].private_key_path == null
    timeout             = local.conn[each.key].timeout
    bastion_host        = local.conn[each.key].bastion_host
    bastion_port        = local.conn[each.key].bastion_port
    bastion_user        = local.conn[each.key].bastion_user
    bastion_private_key = local.conn[each.key].bastion_private_key_path == null ? null : file(local.conn[each.key].bastion_private_key_path)
  }

  provisioner "file" {
    content     = local.airflow_script[each.key]
    destination = "${var.staging_dir}/airflow.sh"
  }

  provisioner "remote-exec" {
    inline = ["${local.conn[each.key].sudo}bash ${var.staging_dir}/airflow.sh; rc=$?; rm -f ${var.staging_dir}/airflow.sh; exit $rc"]
  }

  depends_on = [terraform_data.migrate]
}
