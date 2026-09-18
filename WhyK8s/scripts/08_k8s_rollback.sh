#!/usr/bin/env bash
set -e
kubectl rollout undo deployment/blueforge
kubectl rollout status deployment/blueforge
