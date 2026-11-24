# Generated once and kept in state. Changing them later restarts the affected containers.

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "random_password" "api_secret_key" {
  length  = 64
  special = false
}

resource "random_password" "user" {
  for_each = var.users

  length  = 24
  special = false
}

# 32 random bytes, URL-safe base64: the format cryptography.fernet expects.
resource "random_bytes" "fernet" {
  length = 32
}

locals {
  fernet_key = var.fernet_key != null ? var.fernet_key : replace(replace(random_bytes.fernet.base64, "+", "-"), "/", "_")

  passwords_json = jsonencode({ for u, _ in var.users : u => random_password.user[u].result })

  registry_auth_json = length(var.registry_auth) == 0 ? "" : jsonencode({
    auths = { for reg, c in var.registry_auth : reg => { auth = base64encode("${c.username}:${c.password}") } }
  })
}
