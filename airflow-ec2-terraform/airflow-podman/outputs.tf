output "api_urls" {
  description = "Airflow UI/API on each api-server host (private address). Put a load balancer in front for more than one."
  value       = [for h in local.hosts_with["api-server"] : "http://${local.ip[h]}:${var.api_server_port}"]
}

output "user_passwords" {
  description = "Generated UI/API passwords. Show with: terraform output -json user_passwords"
  value       = { for u, _ in var.users : u => random_password.user[u].result }
  sensitive   = true
}

output "placement" {
  description = "Components on each host."
  value       = local.roles
}

output "airflow_image" {
  description = "Image the Airflow containers run."
  value       = local.airflow_image
}

output "migration_host" {
  description = "Host that runs airflow db migrate."
  value       = local.migration_host
}

output "inbound_ports" {
  description = "Ports each host must accept. Only relevant across hosts; on a single VM only the UI port needs to be reachable from users."
  value = {
    for h, rs in local.roles : h => concat(
      contains(rs, "api-server") ? [{ port = var.api_server_port, from = "users, load balancer, and every Airflow host (Execution API)" }] : [],
      contains(rs, "postgres") ? [{ port = 5432, from = "every Airflow host" }] : [],
      contains(rs, "redis") ? [{ port = 6379, from = "scheduler and worker hosts" }] : [],
      contains(rs, "worker") || (!local.celery && contains(rs, "scheduler")) ? [{ port = 8793, from = "api-server hosts (task logs)" }] : [],
      contains(rs, "triggerer") ? [{ port = 8794, from = "api-server hosts (triggerer logs)" }] : [],
    )
  }
}
