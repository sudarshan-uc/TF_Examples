# airflow-config: Airflow connections, variables and pools with Terraform

Manages what you set up in Airflow after it is installed: connections, variables and pools. Everything goes through the Airflow 3 REST API (`/api/v2`), using two providers:

| Provider | Job |
|---|---|
| [`Mastercard/restapi`](https://registry.terraform.io/providers/Mastercard/restapi) | One `restapi_object` per connection, variable or pool: POST to create, PATCH to change, DELETE to remove, GET on every plan to detect drift |
| [`hashicorp/external`](https://registry.terraform.io/providers/hashicorp/external) | Runs `scripts/get_airflow_token.py`, which exchanges a user and password for an API token (`POST /auth/token`) |

Use it as its own Terraform root with its own state, after `airflow-podman` (or any other install). It works with any Airflow 3 deployment that has the REST API enabled.

## Requirements

| Where | What |
|---|---|
| Terraform runner | Terraform 1.5+ (1.7+ for `import` blocks with `for_each`), `python3` (standard library only), HTTPS access to the Airflow API server or load balancer |
| Airflow | Airflow 3.x with an API user allowed to manage connections, variables and pools (with SimpleAuthManager, an `admin` user) |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # edit airflow_url and the objects
export AIRFLOW_PASSWORD='<password of airflow_username>'
export TF_VAR_connection_secrets='{"warehouse": {"password": "..."}}'
export TF_VAR_secret_variables='{"partner_api_key": "..."}'
terraform init
terraform plan
terraform apply
```

With `airflow-podman`, the admin password is `terraform output -json user_passwords` in that stack.

In CI, set `AIRFLOW_PASSWORD` and the `TF_VAR_*` secrets from your secrets manager (Vault, AWS Secrets Manager, CI masked variables), and run `terraform plan` on pull requests and `terraform apply` on merge.

### Inputs

| Variable | What it holds | Shown in plans |
|---|---|---|
| `airflow_url` | Airflow base URL; the API is `<url>/api/v2` | yes |
| `airflow_username` | API user (default `admin`). The password goes in `AIRFLOW_PASSWORD`, or an existing token in `AIRFLOW_API_TOKEN` | yes |
| `ca_file` | CA bundle for an internal HTTPS certificate | yes |
| `connections` | Connections keyed by `connection_id`: `conn_type`, `description`, `host`, `port`, `login`, `schema`, `extra` (JSON string) | yes |
| `connection_secrets` | Per connection: `password`, and `extra` (JSON string merged over `connections[id].extra`) | no |
| `airflow_variables` | Variables, key = value (use `jsonencode()` for JSON values) | yes |
| `secret_variables` | Variables whose values must not show in plans | no |
| `pools` | Pools keyed by name: `slots`, `description`, `include_deferred` | yes |
| `default_pool_slots` | Slots for `default_pool`; `null` leaves it alone | yes |
| `extra_sensitive_names` | Names you added to `[core] sensitive_var_conn_names` in Airflow | yes |

A connection that has a secret shows as `(sensitive value)` in plans. Other connections show field by field.

## Day-2 changes

| Change | What you do | What happens in Airflow |
|---|---|---|
| Add an object | Add it to the map, then `terraform apply` | POST |
| Change a field | Edit it, then `terraform apply` | PATCH with every field |
| Remove a field (for example `schema`) | Delete the line, then `terraform apply` | The field is set to null. Every field is sent on PATCH, because Airflow keeps fields that are left out. |
| Rotate a password or secret | Change it in `connection_secrets` / `secret_variables`, then `terraform apply` | PATCH. The plan shows the connection as `(sensitive value)` changed. |
| Rename a key | Change the map key | The old object is deleted and the new one created |
| Remove an object | Delete it from the map | DELETE |
| Stop managing `default_pool` | Set `default_pool_slots = null` | `default_pool` goes back to 128 slots |
| Adopt objects that already exist | Import them (below) | Nothing until the next apply, which makes them match the config |

### Objects that already exist in Airflow

Creating an object that already exists fails with `409` (`Unique constraint violation` or `already exists`). Import it, then apply:

```bash
terraform import 'restapi_object.connection["warehouse"]' /api/v2/connections/warehouse
terraform import 'restapi_object.variable["environment"]' /api/v2/variables/environment
terraform import 'restapi_object.secret_variable["partner_api_key"]' /api/v2/variables/partner_api_key
terraform import 'restapi_object.pool["warehouse_pool"]' /api/v2/pools/warehouse_pool
```

Or, with Terraform 1.7+, an `imports.tf` that you delete after the apply:

```hcl
import {
  for_each = toset(["aws_default", "warehouse"])
  to       = restapi_object.connection[each.key]
  id       = "/api/v2/connections/${each.key}"
}
```

## Drift

Each plan reads every object back from Airflow:

| Out-of-band change (UI, CLI, API) | Plan result |
|---|---|
| A field Terraform sets is changed | Shown as an update; apply reverts it |
| A managed object is deleted | Shown as a create; apply recreates it |
| An unmanaged object is added | Ignored |
| A connection `password` or `extra` is changed | Not detected |
| A variable whose key looks sensitive (`api_key`, `token`, `secret`, `password`, ...) is changed | Not detected |

Airflow returns masked values (`***`) for passwords and for names that look sensitive. It also re-serialises `extra` and masks keys inside it. So these fields can't be compared, and they are listed in `ignore_changes_to`. Changing them in Terraform still updates Airflow.

If a newer Airflow version adds fields to its responses, every plan will show them as `- field = ...`. Add those names to the `*_server_fields` lists in `airflow_objects.tf`.

## Security

- `AIRFLOW_PASSWORD` is read by the token script from the environment, so it is not in the plan or the state.
- The API token is in the state, because data source results are stored there. It is valid for Airflow's `[api_auth] jwt_expiration_time` (24 hours by default).
- Connection passwords and secret variables are in the state in plain text, as with any Terraform-managed secret.
- **Use an encrypted remote backend with restricted access** (see `versions.tf`). Don't commit `terraform.tfvars` if it has secrets.
- For values that must never sit in Terraform state, use an Airflow secrets backend (AWS Secrets Manager, Vault) and keep them out of this stack.

## Known limits

- **restapi is pinned to `~> 2.0.1`.** restapi 3.0.0 never notices objects that were deleted or changed outside Terraform ([issue 377](https://github.com/Mastercard/terraform-provider-restapi/issues/377)). With `ignore_all_server_changes`, its plans fail outright. Move to 3.x only after that is fixed.
- **Airflow must be reachable for every plan,** because the token and the drift check need the API. To remove this stack when Airflow is already gone, run `terraform state rm` on its resources.
- **Users and roles are not managed here.** With SimpleAuthManager they come from the Airflow install (`users` in `airflow-podman`).
- **Object names go into URL paths.** Keep connection IDs, variable keys and pool names to letters, digits, `_`, `-` and `.`.

## What has been tested

On 2026-11-24, with Terraform 1.15, restapi 2.0.1 and external 2.4.2, against Airflow 3.4.0 (Astro Runtime 3.4-1-chainguard) installed by `airflow-podman`.

| Scenario | Result |
|---|---|
| Create two connections (one with a password and a secret extra key), three variables (one JSON, one with a sensitive-looking key), one secret variable, one pool, and `default_pool` slots | Created; the next plan was a no-op |
| Out-of-band changes: connection host, pool slots, `default_pool` slots, variable value, secret variable value; one connection and one variable deleted | All detected; apply reverted the changes and recreated the deleted objects; the next plan was a no-op |
| Config changes: port changed, `schema` removed, password and secret extra rotated, variable renamed, pool slots changed, `default_pool_slots` removed | `schema` cleared to null; the new password and extra were confirmed in the Airflow database; rename was a delete and create; `default_pool` went back to 128 |
| Objects created outside Terraform | Apply failed with 409; after `terraform import` (and an `import` block) the next apply changed them to match config |
| `AIRFLOW_PASSWORD` unset, wrong password, Airflow unreachable | Plan stopped with a clear message from the token script |
| `terraform destroy` | Every managed object removed, `default_pool` back to 128 |
| restapi 3.0.0 | Rejected: out-of-band changes and deletions were not detected |

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Provider pins and the backend example |
| `main.tf` | Token data source and restapi provider |
| `variables.tf` | Inputs |
| `airflow_objects.tf` | Connections, variables, pools, `default_pool` |
| `outputs.tf` | Names of managed objects |
| `scripts/get_airflow_token.py` | Token exchange for the external data source |
| `terraform.tfvars.example` | Starting point |
