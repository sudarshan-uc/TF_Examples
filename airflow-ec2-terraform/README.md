# Terraform: Airflow dev environment on EC2 (Astro Runtime 3.4 Chainguard + Podman)

Two Terraform stacks, applied in order:

| Folder | Providers | What it does |
|---|---|---|
| `infra/` | `hashicorp/aws`, `hashicorp/random` | Creates EC2, EFS, PostgreSQL RDS and the load balancer. The EC2 setup script installs Podman, builds the Astro Runtime `3.4-1-chainguard` image and starts Airflow. Optionally re-runs the deploy on the VM through AWS Systems Manager. |
| `airflow-config/` | `Mastercard/restapi`, `hashicorp/external` | Configures Airflow itself through its REST API: connections, variables and pools. |

### Which tool configures what

| Layer | Configured by | Notes |
|---|---|---|
| AWS resources | `aws` provider (`infra/`) | |
| VM and Podman, first boot | EC2 user data (`infra/user_data.sh.tftpl`) | Runs once when the instance is created. |
| VM and Podman, later changes | `aws_ssm_association` (`infra/ssm_deploy.tf`) | Re-runs `airflow-deploy` on the VM without replacing it. No network path from Terraform to the VM needed. |
| Airflow connections, variables, pools | `restapi` provider (`airflow-config/`) | Calls `/api/v2/connections`, `/api/v2/variables`, `/api/v2/pools`. |
| Airflow API token | `external` data source (`airflow-config/`) | Runs `scripts/get_airflow_token.py` to call `POST /auth/token`. |

The `restapi` and `external` providers are not used to configure the VM or Podman:
- `external` only offers a data source. It runs a script on the machine running Terraform at every plan, and has no create/update/destroy lifecycle, so it can't manage anything on the VM.
- `restapi` could only reach Podman if the Podman API were exposed over the network from the VM, which grants root-level control of the host. Podman's API also doesn't map to simple create/read/update/delete objects (image builds, start/stop actions).

## Before you start

- Terraform 1.5 or newer, AWS credentials for the target account, and `python3` on the machine running Terraform (for `airflow-config/`).
- An existing VPC with at least 2 private subnets in different AZs.
- The private subnets need outbound access to `quay.io` (Runtime image), PyPI, your Git server and AWS APIs (Systems Manager).
- The machine running `airflow-config/` must be able to reach the Airflow URL (the load balancer is internal by default).
- Optional: an ACM certificate (HTTPS) and a Route 53 hosted zone (friendly URL).
- Optional: your Astro project repo:
  ```
  your-repo/
  ├── Dockerfile          FROM quay.io/astronomer/astro-runtime:3.4-1-chainguard
  ├── requirements.txt
  ├── packages.txt        Chainguard (apk) package names
  └── dags/
  ```

## Step 1: infrastructure (`infra/`)

| File | What it creates |
|---|---|
| `versions.tf` | Provider versions, AWS provider, optional S3 backend |
| `variables.tf` | All inputs |
| `main.tf` | AMI lookup, generated passwords/keys |
| `security_groups.tf` | Security groups for ALB, EC2, RDS, EFS |
| `ec2.tf` | EC2 instance and IAM role (Session Manager access) |
| `efs.tf` | EFS file system and mount targets (mounted at `/opt/airflow`) |
| `rds.tf` | PostgreSQL RDS instance |
| `alb.tf` | Load balancer, target group, listeners, optional DNS record |
| `ssm_deploy.tf` | Optional redeploy on the VM through Systems Manager |
| `outputs.tf` | URL, login, instance ID, endpoints |
| `user_data.sh.tftpl` | First-boot script: mounts EFS, builds the image, migrates the DB, starts Airflow |

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edit: vpc_id, subnets, allowed_cidrs; optionally certificate_arn, hostname, dag_repo_url

terraform init
terraform plan
terraform apply
```

`apply` takes about 10–15 minutes (RDS is the slowest part). The instance needs about 5–10 more minutes to build the image and start Airflow.

```bash
terraform output airflow_url
terraform output airflow_admin_username
terraform output -raw airflow_admin_password
```

## Step 2: Airflow configuration (`airflow-config/`)

| File | What it does |
|---|---|
| `versions.tf` | `restapi` and `external` provider versions, optional S3 backend |
| `main.tf` | Gets an API token with the `external` data source; configures the `restapi` provider |
| `airflow_objects.tf` | Connections, variables and pools as `restapi_object` resources |
| `variables.tf` | Inputs |
| `scripts/get_airflow_token.py` | Calls `POST /auth/token` and returns the token as JSON |

```bash
cd ../airflow-config
cp terraform.tfvars.example terraform.tfvars
# edit: airflow_url (from infra output), connections, airflow_variables, pools

export TF_VAR_airflow_password="$(terraform -chdir=../infra output -raw airflow_admin_password)"

terraform init
terraform plan
terraform apply
```

Each plan/apply fetches a fresh token, so expiry is not an issue.

How it behaves:
- Adding an entry creates it in Airflow, changing it updates it (`PATCH`), and removing it deletes it.
- Terraform pushes your values but does not detect changes made in the Airflow UI (`ignore_all_server_changes`), because Airflow returns masked passwords and live counters.
- Connection passwords end up in this stack's state; keep the state in a restricted S3 bucket.
- Don't add `default_pool` to `pools`; Airflow creates it automatically.
- If the connection, variable or pool already exists in Airflow (for example from a manual import), delete it first or the create fails.

## Connect to the instance

No SSH key is needed. Use Session Manager (requires the AWS CLI Session Manager plugin):

```bash
$(terraform -chdir=infra output -raw connect_command)
sudo -i
```

Setup log: `/var/log/airflow-setup.log`

## Everyday use

| I want to… | Do this |
|---|---|
| Deploy DAG changes | On the instance: `cd /opt/airflow/project && git pull` |
| Add a Python/OS package or upgrade the Runtime tag | Push to the repo, then either run `airflow-deploy` on the instance, or set/change `deploy_version` in `infra/terraform.tfvars` and `terraform apply` (output in Systems Manager > Run Command) |
| Add or change connections, variables, pools | Edit `airflow-config/terraform.tfvars`, then `terraform apply` |
| Restart Airflow | On the instance: `airflow-start` |
| See containers and logs | `podman ps`, `podman logs -f airflow-scheduler` (DAG import errors: `airflow-dag-processor`) |
| Run an Airflow CLI command | `podman exec -it airflow-scheduler airflow dags list` |

## Change the infrastructure

Edit `infra/terraform.tfvars` (or the `.tf` files), then `terraform plan` and `terraform apply`.

- A change that affects the first-boot script (for example `dag_repo_url`) replaces the EC2 instance. The repo checkout and logs on EFS and the database on RDS are kept, so connections, variables and pools remain.
- To move to a newer Amazon Linux AMI: `terraform apply -replace=aws_instance.airflow`

## Tear down

```bash
cd airflow-config && terraform destroy
cd ../infra
# set db_deletion_protection = false in terraform.tfvars, then:
terraform apply
terraform destroy
```

## Reusing for UAT and production

Copy both folders (or use Terraform workspaces) with separate `terraform.tfvars` and state per environment. Typical changes: `name`, subnets, `allowed_cidrs`, `instance_type`, `db_instance_class`, `certificate_arn`/`hostname`, and the connection values in `airflow-config/`.
