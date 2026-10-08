#!/usr/bin/env bash
# Shared settings for the certbot scripts. Sourced, never run directly.
#
# Loads cert.env from the repo root and defines:
#   ROOT, CERTBOT_DIR, CERTBOT_ARGS (config/work/logs dirs), CERT_NAME,
#   az_dns  (az network dns ... with the right subscription)
#   kctl    (kubectl with the right context)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$ROOT/cert.env" ]]; then
  echo "ERROR: $ROOT/cert.env not found" >&2
  exit 1
fi
# shellcheck source=../cert.env
source "$ROOT/cert.env"

: "${CERT_EMAIL:?set CERT_EMAIL in cert.env}"
: "${CERT_DOMAINS:?set CERT_DOMAINS in cert.env}"
: "${DNS_ZONE:?set DNS_ZONE in cert.env}"
: "${DNS_RG:?set DNS_RG in cert.env}"
: "${K8S_NAMESPACE:?set K8S_NAMESPACE in cert.env}"
: "${K8S_SECRET:?set K8S_SECRET in cert.env}"
STAGING="${STAGING:-1}"

# certbot keeps everything (account, keys, certs, renewal config) here instead
# of /etc/letsencrypt, so it runs without sudo. Keep this folder private and
# out of Git: it contains your private key.
CERTBOT_DIR="$ROOT/.certbot"
# shellcheck disable=SC2034  # used by the scripts that source this file
CERTBOT_ARGS=(
  --config-dir "$CERTBOT_DIR/config"
  --work-dir   "$CERTBOT_DIR/work"
  --logs-dir   "$CERTBOT_DIR/logs"
)

# The certificate's name is its first domain, minus any wildcard prefix.
CERT_NAME="${CERT_DOMAINS%%,*}"
CERT_NAME="${CERT_NAME#\*.}"

az_dns() {
  if [[ -n "${AZ_SUBSCRIPTION:-}" ]]; then
    az network dns "$@" --subscription "$AZ_SUBSCRIPTION"
  else
    az network dns "$@"
  fi
}

kctl() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

need() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: '$cmd' is not installed or not on PATH" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}
