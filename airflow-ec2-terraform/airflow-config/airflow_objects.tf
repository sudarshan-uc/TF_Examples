# Airflow connections, variables and pools managed as Terraform resources.
# Create = POST, update = PATCH, delete = DELETE on /api/v2/<type>/<id>.
#
# ignore_all_server_changes: Airflow returns extra/redacted fields (e.g. masked
# passwords, pool slot counters), so Terraform pushes your values but does not
# report drift from the server.

resource "restapi_object" "connection" {
  for_each = nonsensitive(toset(keys(var.connections)))

  path                      = "/api/v2/connections"
  id_attribute              = "connection_id"
  update_method             = "PATCH"
  ignore_all_server_changes = true

  data = jsonencode(merge(
    { connection_id = each.key },
    { for k, v in var.connections[each.key] : k => v if v != null },
  ))
}

resource "restapi_object" "variable" {
  for_each = var.airflow_variables

  path                      = "/api/v2/variables"
  id_attribute              = "key"
  update_method             = "PATCH"
  ignore_all_server_changes = true

  data = jsonencode({
    key   = each.key
    value = each.value
  })
}

resource "restapi_object" "pool" {
  for_each = var.pools

  path                      = "/api/v2/pools"
  id_attribute              = "name"
  update_method             = "PATCH"
  ignore_all_server_changes = true

  data = jsonencode({
    name             = each.key
    slots            = each.value.slots
    description      = each.value.description
    include_deferred = each.value.include_deferred
  })
}
