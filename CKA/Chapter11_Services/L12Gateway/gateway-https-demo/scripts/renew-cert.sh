#!/usr/bin/env bash
# Renew the certificate if it's within 30 days of expiry, and push the new
# one to the cluster. Safe to run as often as you like; when nothing is due,
# certbot does nothing and the Secret is left alone.
#
# Usage:
#   ./scripts/renew-cert.sh            # renew only if due
#   ./scripts/renew-cert.sh --force    # renew now (for demos and testing)
#   ./scripts/renew-cert.sh --dry-run  # full rehearsal against Let's Encrypt staging
#                                      # (real DNS challenge, nothing saved or deployed)
#
# Let's Encrypt certificates last 90 days. Run this daily from cron, e.g.:
#   17 3 * * *  /path/to/gateway-https-demo/scripts/renew-cert.sh >> /path/to/gateway-https-demo/.certbot/renew.log 2>&1
set -euo pipefail
source "$(dirname "$0")/common.sh"
need certbot az kubectl openssl

EXTRA_ARGS=()
# Plain runs keep certbot's random start delay (up to ~8 min), which spreads
# cron jobs out so Let's Encrypt isn't hit by everyone at 03:00 sharp. Hand
# runs with --force or --dry-run skip it so you get an answer right away.
case "${1:-}" in
  --force)   EXTRA_ARGS+=(--force-renewal --no-random-sleep-on-renew) ;;
  --dry-run) EXTRA_ARGS+=(--dry-run --no-random-sleep-on-renew) ;;
  "")        ;;
  *) echo "Usage: $0 [--force|--dry-run]" >&2; exit 1 ;;
esac

if ! az account show -o none 2>/dev/null; then
  echo "ERROR: az CLI is not logged in. Run 'az login' first." >&2
  exit 1
fi

echo ">> $(date -u +%FT%TZ) checking certificate '$CERT_NAME'"
# The DNS hooks and settings were saved by issue-cert.sh in the renewal
# config, so certbot reuses them. --deploy-hook runs only when a new
# certificate was actually issued (never on --dry-run).
certbot renew "${CERTBOT_ARGS[@]}" \
  --non-interactive \
  --cert-name "$CERT_NAME" \
  --deploy-hook "$ROOT/scripts/load-cert-secret.sh" \
  "${EXTRA_ARGS[@]}"
