output "connection_ids" {
  value = keys(restapi_object.connection)
}

output "variable_keys" {
  value = keys(restapi_object.variable)
}

output "pool_names" {
  value = keys(restapi_object.pool)
}
