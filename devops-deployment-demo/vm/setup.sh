#!/usr/bin/env bash
#
# VM deployment script (Ubuntu/Debian).
# Run this ON the VM, as a user with sudo. It installs the app the "traditional"
# way: system packages, a virtualenv, a dedicated user, and a systemd service.
#
# Usage:
#   sudo bash setup.sh
#
set -euo pipefail

APP_USER="myapp"
APP_DIR="/opt/myapp"
REPO_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"

echo "==> 1/6 Installing system dependencies"
apt-get update -y
apt-get install -y python3 python3-venv python3-pip

echo "==> 2/6 Creating service user '${APP_USER}'"
if ! id "${APP_USER}" &>/dev/null; then
  useradd --system --create-home --shell /usr/sbin/nologin "${APP_USER}"
fi

echo "==> 3/6 Copying application to ${APP_DIR}"
mkdir -p "${APP_DIR}"
cp -r "${REPO_APP_DIR}/." "${APP_DIR}/"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

echo "==> 4/6 Creating Python virtualenv and installing packages"
sudo -u "${APP_USER}" python3 -m venv "${APP_DIR}/venv"
sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install --upgrade pip
sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

echo "==> 5/6 Installing systemd service"
cp "$(dirname "${BASH_SOURCE[0]}")/myapp.service" /etc/systemd/system/myapp.service
systemctl daemon-reload
systemctl enable myapp
systemctl restart myapp

echo "==> 6/6 Done. Service status:"
sleep 1
systemctl --no-pager status myapp || true

echo
echo "App should be live at: http://<this-vm-ip>:8080"
echo "Check logs with:       journalctl -u myapp -f"
