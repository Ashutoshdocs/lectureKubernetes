#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../03-k8s"
docker build -t blueforge:v2 ./app
kubectl set image deployment/blueforge blueforge=blueforge:v2
kubectl set env deployment/blueforge APP_VERSION=v2
kubectl rollout status deployment/blueforge
