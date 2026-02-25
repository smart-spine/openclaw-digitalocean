#!/usr/bin/env bash
set -euo pipefail

FOLLOW=false
SERVICE_NAME="openclaw-gateway"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--follow)
      FOLLOW=true
      ;;
    -h|--help)
      echo "Usage: remote-logs.sh [--follow]"
      exit 0
      ;;
    *)
      echo "Error: unknown option $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "${FOLLOW}" == "true" ]]; then
  journalctl -u "${SERVICE_NAME}" -n 200 --no-pager -f
else
  journalctl -u "${SERVICE_NAME}" -n 200 --no-pager
fi
