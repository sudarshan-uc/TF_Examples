# Optional: re-run the Airflow deploy on the existing VM from Terraform,
# without replacing the instance. Uses AWS Systems Manager (the same agent
# used for Session Manager), so Terraform needs no network path to the VM.
#
# Set deploy_version (any string) to enable. Change it to run again, e.g.
# after updating requirements.txt / packages.txt / the Runtime tag in the repo.
# Output is visible in the AWS console under Systems Manager > Run Command.

resource "aws_ssm_association" "airflow_deploy" {
  count = var.deploy_version == null ? 0 : 1

  name             = "AWS-RunShellScript"
  association_name = "${var.name}-deploy"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.airflow.id]
  }

  parameters = {
    # Wait for first-boot setup to finish, then git pull + build + migrate + restart.
    commands         = "# deploy_version=${var.deploy_version}\ncloud-init status --wait || true\n/usr/local/bin/airflow-deploy"
    executionTimeout = "3600"
  }
}
