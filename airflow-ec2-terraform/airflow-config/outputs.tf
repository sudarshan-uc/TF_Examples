output "connection_ids" {
  description = "Connections managed by this stack."
  value       = keys(restapi_object.connection)
}

output "variable_keys" {
  description = "Variables managed by this stack (plain and secret)."
  value       = concat(keys(restapi_object.variable), keys(restapi_object.secret_variable))
}

output "pool_names" {
  description = "Pools managed by this stack."
  value       = concat(keys(restapi_object.pool), var.default_pool_slots == null ? [] : ["default_pool"])
}
