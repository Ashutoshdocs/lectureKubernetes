#!/usr/bin/env bash
set -e
kubectl scale deployment blueforge --replicas="${1:-5}"
kubectl get pods -l app=blueforge
