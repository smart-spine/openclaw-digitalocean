#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
STATE_DIR="${OPENCLAW_HOME}/.openclaw"
STATE_WORKSPACE_DIR="${STATE_DIR}/workspace"
SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

run_as_openclaw() {
  sudo -u "${OPENCLAW_USER}" env \
    HOME="${OPENCLAW_HOME}" \
    PATH="${SYSTEM_PATH}" \
    OPENCLAW_STATE_DIR="${STATE_DIR}" \
    OPENCLAW_CONFIG_PATH="${STATE_DIR}/openclaw.json" \
    bash -c 'set -a; source "${OPENCLAW_STATE_DIR}/.env"; set +a; "$@"' bash "$@"
}

[[ "$(id -u)" -eq 0 ]] || {
  echo "Error: run as root." >&2
  exit 1
}

[[ -f "${STATE_DIR}/.env" ]] || {
  echo "Error: runtime env not found: ${STATE_DIR}/.env" >&2
  exit 1
}

cd "${STATE_WORKSPACE_DIR}"
run_as_openclaw openclaw dashboard --no-open
