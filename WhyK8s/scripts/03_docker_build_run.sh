#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../02-docker-two-apps"
docker rm -f blueforge greenpulse 2>/dev/null || true
docker build -t blueforge:v1 ./app1
docker build -t greenpulse:v1 ./app2
echo "BlueForge dependencies:"
docker run --rm blueforge:v1 python -c "import jinja2,markupsafe; print(jinja2.__version__, markupsafe.__version__)"
echo "GreenPulse dependencies:"
docker run --rm greenpulse:v1 python -c "import jinja2,markupsafe; print(jinja2.__version__, markupsafe.__version__)"
docker run -d --name blueforge -p 8080:8080 blueforge:v1
docker run -d --name greenpulse -p 8081:8080 greenpulse:v1
docker ps
