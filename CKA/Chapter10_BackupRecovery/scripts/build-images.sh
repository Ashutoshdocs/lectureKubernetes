#!/usr/bin/env bash
# Build the frontend and backend images locally.
# Run this on CLUSTER 1's VM (the one running the app).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building backend image (arcade-backend:v1)"
docker build -t arcade-backend:v1 ./app/backend

echo "==> Building frontend image (arcade-frontend:v1)"
docker build -t arcade-frontend:v1 ./app/frontend

echo "==> Done. Images:"
docker images | grep -E "arcade-(backend|frontend)"
