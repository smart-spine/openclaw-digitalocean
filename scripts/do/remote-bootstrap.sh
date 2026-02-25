#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-}"
DEPLOY_REF="${DEPLOY_REF:-main}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
RUNTIME_ENV_PATH="${RUNTIME_ENV_PATH:-/root/openclaw-runtime.env}"

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
DEPLOY_DIR="${OPENCLAW_HOME}/openclaw-deploy"
STATE_DIR="${OPENCLAW_HOME}/.openclaw"
STATE_WORKSPACE_DIR="${STATE_DIR}/workspace"
AUTH_DIR="${STATE_DIR}/agents/main/agent"
SERVICE_NAME="openclaw-gateway.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

die() {
  echo "Error: $*" >&2
  exit 1
}

apt_retry() {
  local attempt=1
  local max_attempts=5
  local delay=5
  while (( attempt <= max_attempts )); do
    if apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=5 "$@"; then
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    echo "apt-get failed (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
    sleep "${delay}"
    ((attempt++))
  done
  die "apt-get failed after ${max_attempts} attempts: apt-get $*"
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

usage() {
  cat <<'EOF'
Usage: remote-bootstrap.sh --repo-url <URL> --ref <REF> --runtime-env <PATH> [--openclaw-port <PORT>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)
      shift
      [[ $# -gt 0 ]] || die "--repo-url requires a value"
      REPO_URL="$1"
      ;;
    --ref)
      shift
      [[ $# -gt 0 ]] || die "--ref requires a value"
      DEPLOY_REF="$1"
      ;;
    --runtime-env)
      shift
      [[ $# -gt 0 ]] || die "--runtime-env requires a value"
      RUNTIME_ENV_PATH="$1"
      ;;
    --openclaw-port)
      shift
      [[ $# -gt 0 ]] || die "--openclaw-port requires a value"
      OPENCLAW_PORT="$1"
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
[[ -n "${REPO_URL}" ]] || die "REPO_URL is required."
[[ -f "${RUNTIME_ENV_PATH}" ]] || die "Runtime env file not found: ${RUNTIME_ENV_PATH}"

echo "==> Creating user ${OPENCLAW_USER} (if needed)"
if ! id -u "${OPENCLAW_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${OPENCLAW_USER}"
fi

echo "==> Ensuring SSH access for ${OPENCLAW_USER}"
install -d -m 700 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${OPENCLAW_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  install -m 600 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" /root/.ssh/authorized_keys "${OPENCLAW_HOME}/.ssh/authorized_keys"
fi

echo "==> Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt_retry update -y
apt_retry install -y git curl jq ufw ca-certificates gnupg lsb-release

echo "==> Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable

echo "==> Installing Node.js 22"
if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'process.versions.node.split(".")[0]' || true)"
else
  node_major=""
fi
if [[ "${node_major}" != "22" ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt_retry install -y nodejs
fi

echo "==> Cloning deployment repo"
if [[ ! -d "${DEPLOY_DIR}/.git" ]]; then
  sudo -u "${OPENCLAW_USER}" git clone "${REPO_URL}" "${DEPLOY_DIR}"
else
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" remote set-url origin "${REPO_URL}"
fi
sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" fetch --tags --prune origin
if sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" show-ref --verify --quiet "refs/remotes/origin/${DEPLOY_REF}"; then
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" checkout --force -B "${DEPLOY_REF}" "origin/${DEPLOY_REF}"
elif sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" show-ref --verify --quiet "refs/tags/${DEPLOY_REF}"; then
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" checkout --force "tags/${DEPLOY_REF}"
else
  sudo -u "${OPENCLAW_USER}" git -C "${DEPLOY_DIR}" checkout --force "${DEPLOY_REF}"
fi

echo "==> Installing OpenClaw runtime"
[[ -f "${DEPLOY_DIR}/config/openclaw-version.txt" ]] || die "Missing ${DEPLOY_DIR}/config/openclaw-version.txt in repo ref '${DEPLOY_REF}'. Push deployment files to ${REPO_URL} and retry."
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

echo "==> Preparing state directories"
install -d -m 700 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${STATE_DIR}" "${STATE_WORKSPACE_DIR}" "${AUTH_DIR}"
install -d -m 700 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${STATE_DIR}/agents" "${STATE_DIR}/agents/main"
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${STATE_DIR}/agents" "${STATE_WORKSPACE_DIR}"
chmod 700 "${STATE_DIR}/agents" "${STATE_DIR}/agents/main" "${AUTH_DIR}" "${STATE_WORKSPACE_DIR}"

echo "==> Writing runtime .env"
if ! grep -q '^OPENCLAW_PORT=' "${RUNTIME_ENV_PATH}"; then
  printf "OPENCLAW_PORT=%q\n" "${OPENCLAW_PORT}" >>"${RUNTIME_ENV_PATH}"
fi
install -m 600 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${RUNTIME_ENV_PATH}" "${STATE_DIR}/.env"
rm -f "${RUNTIME_ENV_PATH}"

echo "==> Applying config files"
install -m 600 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${DEPLOY_DIR}/config/openclaw.json" "${STATE_DIR}/openclaw.json"
install -m 644 -o "${OPENCLAW_USER}" -g "${OPENCLAW_USER}" "${DEPLOY_DIR}/config/skills-manifest.txt" "${STATE_DIR}/skills-manifest.txt"

set -a
# shellcheck source=/dev/null
source "${STATE_DIR}/.env"
set +a

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  echo "==> Rendering auth profile for openai:main"
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

if [[ -f "${DEPLOY_DIR}/config/skills-manifest.txt" ]]; then
  echo "==> Installing skills (best effort)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    skill="$(printf "%s" "${line}" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "${skill}" ]] || continue
    if ! sudo -u "${OPENCLAW_USER}" HOME="${OPENCLAW_HOME}" clawhub --workdir "${STATE_DIR}" install --no-input "${skill}"; then
      echo "Warning: skill install failed for ${skill}; continuing."
    fi
  done < "${DEPLOY_DIR}/config/skills-manifest.txt"
fi

echo "==> Installing systemd unit (${SERVICE_NAME})"
cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=OpenClaw Gateway Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OPENCLAW_USER}
Group=${OPENCLAW_USER}
WorkingDirectory=${STATE_WORKSPACE_DIR}
Environment=HOME=${OPENCLAW_HOME}
Environment=OPENCLAW_STATE_DIR=${STATE_DIR}
Environment=OPENCLAW_CONFIG_PATH=${STATE_DIR}/openclaw.json
Environment=PATH=${SYSTEM_PATH}
EnvironmentFile=${STATE_DIR}/.env
ExecStart=${OPENCLAW_BIN} gateway run
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

echo
echo "==> Bootstrap completed."
echo "Service is enabled and will be started after deploy apply + smoke checks."
