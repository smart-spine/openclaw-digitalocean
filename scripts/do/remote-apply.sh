#!/usr/bin/env bash
set -euo pipefail

DEPLOY_REF="${DEPLOY_REF:-}"
OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
DEPLOY_DIR="${OPENCLAW_HOME}/openclaw-deploy"
STATE_DIR="${OPENCLAW_HOME}/.openclaw"
STATE_WORKSPACE_DIR="${STATE_DIR}/workspace"
AUTH_DIR="${STATE_DIR}/agents/main/agent"
DEPLOY_STATE_FILE="${STATE_DIR}/deploy-state.json"
SERVICE_NAME="openclaw-gateway.service"
SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_STARTUP_TIMEOUT_SECONDS="${OPENCLAW_STARTUP_TIMEOUT_SECONDS:-240}"

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: remote-apply.sh --ref <REF>
EOF
}

run_as_openclaw() {
  sudo -u "${OPENCLAW_USER}" env \
    HOME="${OPENCLAW_HOME}" \
    PATH="${SYSTEM_PATH}" \
    OPENCLAW_STATE_DIR="${STATE_DIR}" \
    OPENCLAW_CONFIG_PATH="${STATE_DIR}/openclaw.json" \
    bash -c 'set -a; source "${OPENCLAW_STATE_DIR}/.env"; set +a; "$@"' bash "$@"
}

resolve_installed_openclaw_version() {
  local global_node_modules=""
  local package_json_path=""
  global_node_modules="$(npm root -g 2>/dev/null || true)"
  package_json_path="${global_node_modules}/openclaw/package.json"
  if [[ -f "${package_json_path}" ]]; then
    node -e 'const pkg = require(process.argv[1]); process.stdout.write(pkg.version || "");' "${package_json_path}" 2>/dev/null || true
    return 0
  fi
  for package_json_path in \
    "/usr/lib/node_modules/openclaw/package.json" \
    "/usr/local/lib/node_modules/openclaw/package.json"; do
    if [[ -f "${package_json_path}" ]]; then
      node -e 'const pkg = require(process.argv[1]); process.stdout.write(pkg.version || "");' "${package_json_path}" 2>/dev/null || true
      return 0
    fi
  done
  if command -v openclaw >/dev/null 2>&1; then
    openclaw --version 2>/dev/null | awk 'NR==1{print $NF}' | tr -d '[:space:]' || true
  fi
}

install_openclaw_runtime() {
  local openclaw_version="$1"
  local global_node_modules=""
  global_node_modules="$(npm root -g 2>/dev/null || true)"

  if npm install -g "openclaw@${openclaw_version}" clawhub; then
    return 0
  fi

  echo "Initial npm install failed; cleaning stale npm temp directories and retrying once."
  if [[ -n "${global_node_modules}" && -d "${global_node_modules}" ]]; then
    find "${global_node_modules}" -maxdepth 1 -mindepth 1 -type d \
      \( -name '.openclaw-*' -o -name '.clawhub-*' \) -exec rm -rf {} +
  fi
  npm install -g "openclaw@${openclaw_version}" clawhub
}

install_skills_best_effort() {
  local manifest_path="${1}"
  [[ -f "${manifest_path}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    local skill
    skill="$(printf "%s" "${line}" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "${skill}" ]] || continue
    if ! run_as_openclaw clawhub --workdir "${STATE_DIR}" install --no-input "${skill}"; then
      echo "Warning: skill install failed for ${skill}; continuing."
    fi
  done < "${manifest_path}"
}

run_as_openclaw_with_timeout() {
  local timeout_seconds="$1"
  shift
  timeout "${timeout_seconds}" sudo -u "${OPENCLAW_USER}" env \
    HOME="${OPENCLAW_HOME}" \
    PATH="${SYSTEM_PATH}" \
    OPENCLAW_STATE_DIR="${STATE_DIR}" \
    OPENCLAW_CONFIG_PATH="${STATE_DIR}/openclaw.json" \
    bash -c 'set -a; source "${OPENCLAW_STATE_DIR}/.env"; set +a; "$@"' bash "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      shift
      [[ $# -gt 0 ]] || die "--ref requires a value"
      DEPLOY_REF="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] || die "Run as root."
[[ -n "${DEPLOY_REF}" ]] || die "Missing --ref."
[[ -d "${DEPLOY_DIR}/.git" ]] || die "Deployment repo not found: ${DEPLOY_DIR}"
[[ -f "${STATE_DIR}/.env" ]] || die "Missing runtime env file: ${STATE_DIR}/.env"

previous_ref="$(sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" rev-parse HEAD 2>/dev/null || true)"

echo "==> Fetching repo updates"
sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" fetch --tags --prune origin
if sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" show-ref --verify --quiet "refs/remotes/origin/${DEPLOY_REF}"; then
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" checkout --force -B "${DEPLOY_REF}" "origin/${DEPLOY_REF}"
elif sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" show-ref --verify --quiet "refs/tags/${DEPLOY_REF}"; then
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" checkout --force "tags/${DEPLOY_REF}"
else
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" checkout --force "${DEPLOY_REF}"
fi
current_ref="$(sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" rev-parse HEAD)"

echo "==> Applying config"
install -d -m 700 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${STATE_DIR}" "${STATE_WORKSPACE_DIR}" "${AUTH_DIR}"
install -d -m 700 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${STATE_DIR}/agents" "${STATE_DIR}/agents/main"
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${STATE_DIR}/agents" "${STATE_WORKSPACE_DIR}"
chmod 700 "${STATE_DIR}/agents" "${STATE_DIR}/agents/main" "${AUTH_DIR}" "${STATE_WORKSPACE_DIR}"
install -m 600 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${DEPLOY_DIR}/config/openclaw.json" "${STATE_DIR}/openclaw.json"
install -m 644 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${DEPLOY_DIR}/config/skills-manifest.txt" "${STATE_DIR}/skills-manifest.txt"

set -a
# shellcheck source=/dev/null
source "${STATE_DIR}/.env"
set +a
cd "${STATE_WORKSPACE_DIR}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  auth_tmp="$(mktemp)"
  jq -n --arg api_key "${OPENAI_API_KEY}" '{
    version: 1,
    profiles: {
      "openai:main": {
        type: "api_key",
        provider: "openai",
        key: $api_key
      }
    },
    order: {
      openai: ["openai:main"]
    }
  }' >"${auth_tmp}"
  install -m 600 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${auth_tmp}" "${AUTH_DIR}/auth-profiles.json"
  rm -f "${auth_tmp}"
fi

echo "==> Updating OpenClaw runtime"
OPENCLAW_VERSION="$(tr -d '[:space:]' < "${DEPLOY_DIR}/config/openclaw-version.txt")"
[[ -n "${OPENCLAW_VERSION}" ]] || die "config/openclaw-version.txt is empty."
INSTALLED_OPENCLAW_VERSION="$(resolve_installed_openclaw_version)"
OPENCLAW_BIN="$(command -v openclaw || true)"
if [[ "${INSTALLED_OPENCLAW_VERSION}" != "${OPENCLAW_VERSION}" || ! -x "${OPENCLAW_BIN}" ]]; then
  echo "Installing openclaw@${OPENCLAW_VERSION} (current: ${INSTALLED_OPENCLAW_VERSION:-none})"
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    systemctl stop "${SERVICE_NAME}"
  fi
  install_openclaw_runtime "${OPENCLAW_VERSION}"
else
  echo "openclaw@${OPENCLAW_VERSION} already installed; skipping npm install."
fi
OPENCLAW_BIN="$(command -v openclaw || true)"
[[ -x "${OPENCLAW_BIN}" ]] || die "openclaw binary not found after npm install."

install_skills_best_effort "${DEPLOY_DIR}/config/skills-manifest.txt"

echo "==> Restarting ${SERVICE_NAME}"
systemctl daemon-reload
systemctl restart "${SERVICE_NAME}"
systemctl is-active --quiet "${SERVICE_NAME}" || die "${SERVICE_NAME} is not active after restart."
sleep 5
systemctl is-active --quiet "${SERVICE_NAME}" || die "${SERVICE_NAME} failed shortly after restart."
if ! timeout "${OPENCLAW_STARTUP_TIMEOUT_SECONDS}" bash -c "until ss -ltn | grep -E -q '[:.]${OPENCLAW_PORT}[[:space:]]'; do sleep 2; done"; then
  die "Gateway port ${OPENCLAW_PORT} did not start listening in time."
fi

echo "==> Health checks"
if ! run_as_openclaw_with_timeout 120 openclaw models status --check; then
  die "Model status check failed or timed out."
fi
if ! agent_output="$(run_as_openclaw_with_timeout 180 openclaw agent --local --agent main -m "Reply with OPENCLAW_OK only" --json --timeout 120)"; then
  die "Agent smoke test command failed or timed out."
fi
if ! printf "%s" "${agent_output}" | jq -e 'tostring | test("OPENCLAW_OK")' >/dev/null; then
  die "Smoke test failed: OPENCLAW_OK marker not found."
fi

previous_current_ref=""
previous_last_good_ref=""
if [[ -f "${DEPLOY_STATE_FILE}" ]]; then
  previous_current_ref="$(jq -r '.current_ref // empty' "${DEPLOY_STATE_FILE}")"
  previous_last_good_ref="$(jq -r '.last_good_ref // empty' "${DEPLOY_STATE_FILE}")"
fi

last_good_ref="${current_ref}"
if [[ -n "${previous_current_ref}" && "${previous_current_ref}" != "${current_ref}" ]]; then
  last_good_ref="${previous_current_ref}"
elif [[ -n "${previous_ref}" && "${previous_ref}" != "${current_ref}" ]]; then
  last_good_ref="${previous_ref}"
elif [[ -n "${previous_last_good_ref}" ]]; then
  last_good_ref="${previous_last_good_ref}"
fi

state_tmp="$(mktemp)"
jq -n \
  --arg last_good_ref "${last_good_ref}" \
  --arg current_ref "${current_ref}" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{last_good_ref:$last_good_ref,current_ref:$current_ref,timestamp:$timestamp}' >"${state_tmp}"
install -m 600 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${state_tmp}" "${DEPLOY_STATE_FILE}"
rm -f "${state_tmp}"

echo "==> Deploy state updated: ${DEPLOY_STATE_FILE}"
cat "${DEPLOY_STATE_FILE}"
echo
echo "==> Apply completed for ref ${current_ref}"
