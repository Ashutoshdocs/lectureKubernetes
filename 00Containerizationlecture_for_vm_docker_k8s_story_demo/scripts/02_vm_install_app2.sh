#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../01-vm-two-apps"
source shared-env/bin/activate
pip install -q -r app2/requirements.txt
echo "Shared environment AFTER App 2:"
pip freeze | grep -E "Jinja|Markup"
echo "Now run: python app2/app.py"
echo "Then stop it and run: python app1/app.py"
echo "Expected: ImportError involving markupsafe.soft_unicode"
