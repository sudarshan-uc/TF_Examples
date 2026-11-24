#!/usr/bin/env python3
"""Terraform external data source: returns an Airflow 3 API token.

Input (stdin, JSON): {"airflow_url": "...", "username": "...", "ca_file": ""}
Output (stdout, JSON): {"access_token": "..."}

Credentials come from the environment, not from the query, so they stay out of
the Terraform plan and state:
  AIRFLOW_API_TOKEN  an existing token; returned as-is
  AIRFLOW_PASSWORD   password for "username"; exchanged at POST /auth/token
"""
import json
import os
import ssl
import sys
import urllib.error
import urllib.request


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


query = json.load(sys.stdin)
url = query["airflow_url"].rstrip("/") + "/auth/token"

token = os.environ.get("AIRFLOW_API_TOKEN")
if token:
    json.dump({"access_token": token}, sys.stdout)
    sys.exit(0)

password = os.environ.get("AIRFLOW_PASSWORD")
if not password:
    fail("Set AIRFLOW_PASSWORD (password for %s) or AIRFLOW_API_TOKEN before running Terraform." % query["username"])

context = ssl.create_default_context(cafile=query.get("ca_file") or None)
request = urllib.request.Request(
    url,
    data=json.dumps({"username": query["username"], "password": password}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=30, context=context) as response:
        token = json.load(response)["access_token"]
except urllib.error.HTTPError as exc:
    fail("POST %s returned HTTP %s: %s" % (url, exc.code, exc.read().decode(errors="replace")[:300]))
except Exception as exc:  # network, TLS, bad JSON
    fail("Could not get an Airflow API token from %s: %s" % (url, exc))

json.dump({"access_token": token}, sys.stdout)
