#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../03-k8s"
docker build -t blueforge:v1 ./app
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl rollout status deployment/blueforge
kubectl get pods -l app=blueforge -o wide
