# Connections, variables and pools as restapi_object resources on the Airflow 3
# REST API: create = POST <path>, read = GET <path>/<id>, update = PATCH
# <path>/<id>, delete = DELETE <path>/<id>.
#
# Drift: on every plan Terraform reads each object back. Changes made in the UI
# or CLI are reverted, and objects deleted there are recreated. Exceptions, all
# listed in ignore_changes_to:
#   - Fields only Airflow sets (team_name, is_encrypted, pool slot counters).
#   - Values Airflow masks as "***": connection passwords, and variables whose
#     key looks sensitive (api_key, token, secret, ... see sensitive_names).
#   - Connection extra: Airflow re-serialises it and masks sensitive keys in it.
# Changing any of these in Terraform still updates Airflow; only changes made
# outside Terraform go unnoticed. A newer Airflow that returns new fields shows
# them as "- field = ..." in every plan; add them to the server_fields lists.

locals {
  # Airflow's default sensitive names (secrets_masker DEFAULT_SENSITIVE_FIELDS),
  # matched as substrings of the lower-cased name with non-word runs replaced by "_".
  sensitive_names = concat([
    "access_key", "access_token", "api_key", "apikey", "auth_header", "authorization",
    "bearer", "connection_string", "dsn", "passphrase", "passwd", "password",
    "private_key", "proxy", "proxy_password", "proxies", "secret", "service_account",
    "service_key", "token", "keyfile_dict", "webhook_url",
  ], [for n in var.extra_sensitive_names : lower(n)])

  # Fields Airflow 3.x returns that this stack never sets.
  connection_server_fields = ["team_name"]
  variable_server_fields   = ["description", "is_encrypted", "team_name"]
  pool_server_fields = [
    "deferred_slots", "occupied_slots", "open_slots", "queued_slots",
    "running_slots", "scheduled_slots", "team_name",
  ]

  conn_secret = {
    for id in keys(var.connections) : id => {
      password = try(var.connection_secrets[id].password, null)
      extra    = try(var.connection_secrets[id].extra, null)
    }
  }

  conn_extra = {
    for id, c in var.connections : id => (
      c.extra == null && local.conn_secret[id].extra == null ? null : jsonencode(merge(
        c.extra == null ? {} : jsondecode(c.extra),
        local.conn_secret[id].extra == null ? {} : jsondecode(local.conn_secret[id].extra),
      ))
    )
  }

  # Whether a key looks sensitive to Airflow, so its value comes back as "***".
  variable_masked = {
    for k in concat(keys(var.airflow_variables), nonsensitive(keys(var.secret_variables))) : k => anytrue([
      for w in local.sensitive_names : strcontains(replace(lower(k), "/\\W+/", "_"), w)
    ])
  }
}

check "connection_secrets_match" {
  assert {
    condition     = alltrue([for id in nonsensitive(keys(var.connection_secrets)) : contains(keys(var.connections), id)])
    error_message = "connection_secrets has keys that are not in connections; those secrets are not applied."
  }
}

check "variables_do_not_overlap" {
  assert {
    condition     = length(setintersection(keys(var.airflow_variables), nonsensitive(keys(var.secret_variables)))) == 0
    error_message = "A key is in both airflow_variables and secret_variables."
  }
}

resource "restapi_object" "connection" {
  for_each = var.connections

  path          = "/api/v2/connections"
  id_attribute  = "connection_id"
  update_method = "PATCH"
  ignore_changes_to = concat(
    local.connection_server_fields,
    ["extra"],
    nonsensitive(local.conn_secret[each.key].password != null) ? ["password"] : [],
  )

  # Every field is sent, null included: Airflow's PATCH keeps fields that are
  # left out, so a field removed here would otherwise stay set in Airflow.
  data = jsonencode({
    connection_id = each.key
    conn_type     = each.value.conn_type
    description   = each.value.description
    host          = each.value.host
    port          = each.value.port
    login         = each.value.login
    schema        = each.value.schema
    password      = local.conn_secret[each.key].password
    extra         = local.conn_extra[each.key]
  })
}

resource "restapi_object" "variable" {
  for_each = var.airflow_variables

  path              = "/api/v2/variables"
  id_attribute      = "key"
  update_method     = "PATCH"
  ignore_changes_to = concat(local.variable_server_fields, local.variable_masked[each.key] ? ["value"] : [])

  data = jsonencode({ key = each.key, value = each.value })
}

resource "restapi_object" "secret_variable" {
  for_each = nonsensitive(toset(keys(var.secret_variables)))

  path              = "/api/v2/variables"
  id_attribute      = "key"
  update_method     = "PATCH"
  ignore_changes_to = concat(local.variable_server_fields, local.variable_masked[each.key] ? ["value"] : [])

  data = jsonencode({ key = each.key, value = var.secret_variables[each.key] })
}

resource "restapi_object" "pool" {
  for_each = var.pools

  path              = "/api/v2/pools"
  id_attribute      = "name"
  update_method     = "PATCH"
  ignore_changes_to = local.pool_server_fields

  # PATCH on a pool needs every field (422 otherwise).
  data = jsonencode({
    name             = each.key
    slots            = each.value.slots
    description      = each.value.description
    include_deferred = each.value.include_deferred
  })
}

# default_pool always exists and can't be deleted, so it is only ever PATCHed,
# and Airflow accepts that only with update_mask limited to these two fields.
# On destroy it goes back to Airflow's default of 128 slots.
resource "restapi_object" "default_pool" {
  count = var.default_pool_slots == null ? 0 : 1

  path              = "/api/v2/pools"
  object_id         = "default_pool"
  create_method     = "PATCH"
  create_path       = "/api/v2/pools/default_pool"
  update_method     = "PATCH"
  destroy_method    = "PATCH"
  query_string      = "update_mask=slots&update_mask=include_deferred"
  id_attribute      = "name"
  ignore_changes_to = concat(local.pool_server_fields, ["description"])

  data = jsonencode({
    name             = "default_pool"
    slots            = var.default_pool_slots
    include_deferred = false
  })

  destroy_data = jsonencode({
    name             = "default_pool"
    slots            = 128
    include_deferred = false
  })
}
