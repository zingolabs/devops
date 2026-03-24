#!/bin/bash
# Get Grafana admin password
kubectl -n monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}" | base64 -d
echo
