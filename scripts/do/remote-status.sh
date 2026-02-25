#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
STATE_DIR="${OPENCLAW_HOME}/.openclaw"
SERVICE_NAME="openclaw-gateway.service"
SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

run_as_openclaw() {
  sudo -u "${OPENCLAW_USER}" env \
    HOME="${OPENCLAW_HOME}" \
    PATH="${SYSTEM_PATH}" \
    OPENCLAW_STATE_DIR="${STATE_DIR}" \
    OPENCLAW_CONFIG_PATH="${STATE_DIR}/openclaw.json" \
    bash -c 'set -a; source "${OPENCLAW_STATE_DIR}/.env"; set +a; "$@"' bash "$@"
}

echo "==> systemctl status ${SERVICE_NAME}"
systemctl --no-pager --full status "${SERVICE_NAME}" || true

echo
echo "==> openclaw models status --plain"
run_as_openclaw openclaw models status --plain || true

echo
echo "==> Disk usage"
df -h /
df -h /home || true

echo
echo "==> Memory usage"
free -h
