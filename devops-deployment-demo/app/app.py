"""
Simple demo web app.

It reports:
  - the hostname it's running on (VM name / container id / pod name)
  - which deployment mode it thinks it's in (from an env var)
  - a version string
  - a visit counter (in-memory, resets on restart)

This makes the difference between VM, Docker and Kubernetes deployments
visible in the browser: on a VM you always see the same hostname, in Docker
you see the container id, and in Kubernetes (when scaled) you see the
hostname change between pods as requests get load-balanced.
"""

import os
import socket
from flask import Flask, jsonify, render_template

app = Flask(__name__)

# Read config from environment (overridable by systemd / Docker / k8s ConfigMap)
DEPLOY_MODE = os.environ.get("DEPLOY_MODE", "unknown")
APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
GREETING = os.environ.get("GREETING", "Hello from the DevOps demo!")

_visits = 0


def _info():
    global _visits
    _visits += 1
    return {
        "greeting": GREETING,
        "hostname": socket.gethostname(),
        "deploy_mode": DEPLOY_MODE,
        "version": APP_VERSION,
        "visits_since_start": _visits,
        "pid": os.getpid(),
    }


@app.route("/")
def index():
    return render_template("index.html", **_info())


@app.route("/api/info")
def api_info():
    return jsonify(_info())


@app.route("/healthz")
def healthz():
    # Used by Docker HEALTHCHECK and Kubernetes liveness/readiness probes
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    # 0.0.0.0 so it's reachable from outside the VM/container
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
