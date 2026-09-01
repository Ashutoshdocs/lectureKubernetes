#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../01-vm-two-apps"
rm -rf shared-env
python3 -m venv shared-env
source shared-env/bin/activate
pip install -q -r app1/requirements.txt
echo "App 1 environment:"
pip freeze | grep -E "Jinja|Markup"
echo "Run: python app1/app.py"
