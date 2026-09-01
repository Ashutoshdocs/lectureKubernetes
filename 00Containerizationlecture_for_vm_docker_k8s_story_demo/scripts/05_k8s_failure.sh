#!/usr/bin/env bash
set -e
POD=$(kubectl get pods -l app=blueforge -o jsonpath='{.items[0].metadata.name}')
echo "Deleting $POD"
kubectl delete pod "$POD"
echo "Watch replacement with:"
echo "kubectl get pods -l app=blueforge -w"
