#!/usr/bin/env python3
"""Terraform external data source: returns an Airflow 3 API token.

Input (stdin, JSON):  {"airflow_url": "...", "username": "...", "password": "..."}
Output (stdout, JSON): {"access_token": "..."}
"""
import json
import sys
import urllib.request

query = json.load(sys.stdin)
request = urllib.request.Request(
    query["airflow_url"].rstrip("/") + "/auth/token",
    data=json.dumps({"username": query["username"], "password": query["password"]}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=30) as response:
        token = json.load(response)["access_token"]
except Exception as exc:  # report on stderr so Terraform shows the reason
    print(f"Could not get an Airflow API token from {query['airflow_url']}: {exc}", file=sys.stderr)
    sys.exit(1)

json.dump({"access_token": token}, sys.stdout)
