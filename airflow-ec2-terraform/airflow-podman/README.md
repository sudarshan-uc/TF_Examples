# airflow-podman: Astro Runtime on existing VMs with Terraform

Installs and runs Airflow from the Astro Runtime image (including the `-chainguard` variants) on Linux VMs you already have. It works on one VM or several. Terraform connects over SSH and leaves the containers as podman quadlet units under systemd. After an apply there are no manual steps on the VM: deploys, config changes, restarts after reboot and teardown are all handled by `terraform apply` / `terraform destroy`.

It does not create VMs, networks, load balancers or databases. You provide those.

## What runs where

```
VM (systemd)
├── /etc/containers/systemd/airflow-*.container   quadlet units written by Terraform
├── /etc/airflow/airflow.env                      Airflow settings and secrets (0600 root)
└── /opt/airflow                                  base_dir
    ├── dags/      synced from <project_dir>/dags, mounted read-only
    ├── logs/      task logs
    ├── config/    SimpleAuthManager password file
    └── postgres/  only with the bundled dev database

Containers (all --network host):
  airflow-db-migrate     oneshot: airflow db migrate, runs before the others
  airflow-api-server     UI, REST API, Execution API
  airflow-scheduler      (LocalExecutor: tasks run here)
  airflow-dag-processor
  airflow-triggerer
  airflow-worker         CeleryExecutor only
  airflow-postgres       only when sql_alchemy_conn is unset (dev/test)
  airflow-redis          only for CeleryExecutor when celery_broker_url is unset (dev/test)
```

Every unit restarts on failure, starts at boot, and has a health check. A failing health check restarts the container. Logs go to journald (`journalctl -u airflow-scheduler`).

## Requirements

| Where | What |
|---|---|
| Terraform runner | Terraform 1.5+, SSH access to every VM (directly or through `ssh.bastion_host`) |
| Each VM | Linux with systemd, podman 4.6+ with quadlet, passwordless `sudo` for the SSH user (or SSH as root), `base64`, `sha256sum`, `timeout` |
| Each VM, network | Pull access to the Runtime image registry (quay.io, astrocrpublic.azurecr.io, or your mirror). With `project_dir`, the build also needs PyPI (or your index) for `requirements.txt` and the Chainguard apk repo for `packages.txt` |
| Database | Postgres 14–18 reachable from every Airflow VM, with an empty database for Airflow. The bundled Postgres container is for dev/test only |

### What has been tested

On 2026-11-24, against a single Fedora CoreOS VM (podman 5.8.4, SELinux enforcing, arm64) with `quay.io/astronomer/astro-runtime:3.4-1-chainguard` (Airflow 3.4.0):

| Scenario | Result |
|---|---|
| Fresh apply: build, bundled Postgres, migrate, 4 components | Passed. A smoke-test DAG ran on LocalExecutor, and its task log was readable through the API. |
| Re-apply with no changes | `plan` reports no changes |
| DAG-only change | Only `base` re-ran. DAGs synced, no rebuild, no restarts. |
| `airflow_env` change | Env rewritten, migrate re-ran, components restarted, new value live |
| Dockerfile change | New image built, migrate, rollout to the new tag, old image removed |
| Container killed | systemd restarted it (`NRestarts=1`) |
| Switch to CeleryExecutor (bundled Redis, worker on the same host) | Passed. The DAG ran on the Celery worker. |
| Switch back to LocalExecutor | Worker, Redis unit and Redis secret removed |
| Unreachable `sql_alchemy_conn` | Failed in about 60s with a clear DB error instead of hanging. The next good apply recovered with data intact. |
| `terraform destroy` with purge | No containers, units, secrets, images, directories or systemd entries left |

Also on 2026-11-24, against three AlmaLinux 10 VMs (kernel 6.12, SELinux enforcing, arm64, no podman preinstalled) on one private network. The layout was: af-a with api-server, dag-processor, triggerer, Postgres and Redis; af-b with scheduler and worker; af-c with a worker on the `default` and `heavy` queues.

| Scenario | Result |
|---|---|
| Fresh apply with `install_podman = true` and `host_key` set | podman installed with dnf, image built on all three hosts, migrate ran on af-b (the scheduler host), all units healthy |
| CeleryExecutor across hosts | Passed. Default-queue tasks ran on af-b and af-c; the `heavy` task ran only on af-c. |
| Task logs across hosts | The API server on af-a served task logs from af-b and af-c (port 8793) |
| Cold restart of af-a (DB, Redis, API server) | Every unit came back at boot and was healthy. The scheduler and worker on af-b recovered without a restart. |
| Moving dag-processor to af-b and triggerer to af-c | Units started on the new hosts and were removed from af-a. Unchanged units were not restarted. |
| Removing af-c from `hosts` | af-c torn down (units, containers, built images, `/etc/airflow`, `/opt/airflow`). The other hosts kept running and a DAG succeeded. |
| `terraform destroy` | Nothing left but the pulled upstream images |

**Not tested yet:**
- Amazon Linux 2023 and RHEL itself (AlmaLinux 10 is the RHEL 10 rebuild).
- x86_64.
- `image` mode, `registry_auth`, `build_netrc`.
- A bastion host.
- An external Postgres or Redis.

### Problems found during testing

- **`host_key` must be the host's ECDSA key** (`/etc/ssh/ssh_host_ecdsa_key.pub`, or `ssh-keyscan -t ecdsa`). Terraform's SSH client negotiates ECDSA when the server has an ECDSA key, so an ed25519 `host_key` fails with `knownhosts: key mismatch`. The same error appears when a VM is rebuilt and its host keys change, which is the check working as intended.
- **VM hostnames don't resolve inside containers on some images.** On AlmaLinux the hostname resolves only through the host's nss-myhostname, which the Runtime image doesn't have. In multi-VM mode the scheduler then crashed with `socket.gaierror`. Every Airflow unit now maps the VM hostname to `private_ip` (`AddHost=%H:<ip>`), so `hostname_callable` always returns the address other hosts use.
- **AlmaLinux 9 on Apple M5 hosts is not usable for local testing.** The 5.14 kernel reports SVE2 that the CPU doesn't have, so `apk` in the Chainguard build dies with SIGILL. This doesn't affect EC2 (Graviton 3/4 have SVE; x86 is unaffected), and AlmaLinux 10 works.
- **Builds use docker format.** `podman build` now runs with `--format docker`. The default OCI format drops the Runtime image's `SHELL` (bash with pipefail), so the build steps ran under `/bin/sh`.

## Usage

```bash
cp examples/single-vm.tfvars.example terraform.tfvars   # edit hosts, ssh, project_dir
export TF_VAR_sql_alchemy_conn='postgresql+psycopg2://airflow:<pw>@db.example.internal:5432/airflow'
terraform init
terraform apply
terraform output api_urls
terraform output -json user_passwords
```

An apply runs four steps in order. Each step re-runs only when its inputs changed.

| Step | Resource | Does |
|---|---|---|
| 1 | `terraform_data.teardown[host]` | Nothing on create. On destroy, or when a host is removed from `hosts`, stops and removes everything this module created on that host. |
| 2 | `terraform_data.base[host]` | Checks podman. Writes `/etc/airflow/*` and the password file. Pulls images, or uploads `project_dir` and runs `podman build`. Syncs DAGs. Starts the bundled Postgres/Redis and waits until they are healthy. |
| 3 | `terraform_data.migrate` | On the first scheduler host: `airflow db check` (fails fast on DB connection problems), then `airflow db migrate`. |
| 4 | `terraform_data.airflow[host]` | Writes the component units, restarts only the ones that changed, waits for the API server health check, and confirms every unit stays up. |

## Day-2 changes

| Change | What you do | What happens on the VM |
|---|---|---|
| DAGs | Change files under `<project_dir>/dags`, then `terraform apply` | DAGs are synced in place. No rebuild, no restart. |
| `requirements.txt`, `packages.txt`, Dockerfile (Runtime upgrade) | Edit, then `terraform apply` | A new image is built and tagged with the content hash. `db migrate` runs, then the components restart on the new image. Old images are removed. |
| Airflow settings | `airflow_env` / `airflow_secret_env`, then `terraform apply` | The env file is rewritten and only the affected containers restart. |
| Users | `users`, then `terraform apply` | Passwords are generated; the API server restarts. |
| Add or move hosts and roles | Edit `hosts` | New units start; units that moved away are removed. A host taken out of `hosts` is torn down. |
| VM rebuilt with the same address | `terraform apply -replace='terraform_data.base["<host>"]' -replace='terraform_data.airflow["<host>"]'` | Everything is reinstalled on that host. |

## Images and DAGs

Choose one of these:

- **`project_dir`** (matches the manual podman guide): an Astro project with `Dockerfile`, `requirements.txt`, `packages.txt` and `dags/`.
  - The project is uploaded and built on every Airflow VM as `localhost/airflow-runtime:<hash>`.
  - `dags/` is mounted from the host, so DAG changes don't need a rebuild.
  - In CI, check out the DAG repo and point `project_dir` at it. Anything in the folder is uploaded, so keep large unrelated files out.
- **`image`**: a prebuilt, scanned image from your registry. With `dags_dir` set, that folder is synced and mounted; without it, the DAGs in the image are used. Use immutable tags. An image that already exists on the host is not pulled again.

**Private index or registry:**
- For a private Python index, put an `--index-url` line in `requirements.txt` and pass credentials as `.netrc` content in `build_netrc`. The Runtime ONBUILD step mounts it as the `netrc` build secret.
- For a private registry, set `registry_auth`. It is written to `/etc/airflow/registry-auth.json` and used for pulls and builds.

**Chainguard images:**
- `packages.txt` takes Wolfi/apk package names, not Debian names.
- The image has no `id`, `curl` or `apk` at run time. Add whatever your BashOperators call to `packages.txt`.

## Single VM vs multiple VMs

**Single VM.** Leave `roles` unset and everything runs on the one host. Services talk over `127.0.0.1`, and only `api_server_port` needs to be reachable by users.

**Multiple VMs.** Set `roles` on every host, and use `executor = "CeleryExecutor"` when you add worker hosts.
- `AIRFLOW__CORE__HOSTNAME_CALLABLE` is set to the host IP, and each Airflow container maps the VM hostname to `private_ip`, so task logs and job heartbeats resolve across hosts without DNS.
- Proxy variables in the SSH session (`HTTP_PROXY` and similar) reach `podman build`, but the running containers don't inherit them. If DAGs need a proxy, set `HTTPS_PROXY` and `NO_PROXY` through `airflow_env`. `NO_PROXY` must include the other hosts' private IPs, so Execution API and log calls don't go through the proxy.
- The Execution API URL defaults to the local API server when the host has one, otherwise the first api-server host. Override it with `execution_api_server_url` when there's a load balancer.
- `terraform output inbound_ports` lists what each host must accept from which other hosts. Opening those ports is the network team's job; this module does not manage host or cloud firewalls.
- Task logs stay on the host that ran the task and are served to the UI on port 8793 (8794 for the triggerer). For durable logs, configure remote logging to S3 through `airflow_env` (the Amazon provider goes in `requirements.txt`).

## Security notes

- Generated secrets (Fernet key, JWT secret, API secret key, user passwords, bundled DB/Redis passwords) are in Terraform state. Use an encrypted backend with restricted access (see `versions.tf`).
- On the VM, secrets live in root-only files under `/etc/airflow`, a podman secret (Redis), and the password file (container user, `0600`). The rendered apply scripts carry secrets and are deleted right after they run. Nothing goes through cloud-init user data.
- Set `host_key` on every host so Terraform verifies the VM it connects to. Use the ECDSA host key (see "Problems found during testing").
- To reuse an existing database with encrypted connections, set `fernet_key` to its current key.
- Auth is Airflow's SimpleAuthManager. FAB isn't in the Runtime image, so SSO/LDAP needs extra work.

## Destroy

`terraform destroy` stops and removes the units, containers, podman secret, built images, `/etc/airflow` and the staging directory on every host. `base_dir` (DAGs, logs, bundled DB data) is kept unless `purge_data_on_destroy = true`. A customer-provided database is never touched.

## Files

| File | Purpose |
|---|---|
| `variables.tf` | Inputs |
| `locals.tf` | Placement, Airflow config, quadlet unit and script rendering |
| `secrets.tf` | Generated secrets |
| `main.tf` | The four SSH steps |
| `outputs.tf` | URLs, passwords, placement, ports |
| `templates/apply.sh.tftpl` | Idempotent per-step script (runs as root on the VM) |
| `templates/unit.container.tftpl` | Quadlet unit |
| `templates/teardown.sh.tftpl` | Destroy-time cleanup |
| `examples/` | tfvars examples and a minimal Astro project with a smoke-test DAG |
