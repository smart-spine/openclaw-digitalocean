#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/config/do.env"
CONFIG_EXAMPLE_FILE="${ROOT_DIR}/config/do.env.example"
SECRETS_FILE="${ROOT_DIR}/secrets/do.env"
SECRETS_EXAMPLE_FILE="${ROOT_DIR}/secrets/do.env.example"
SECRETS_DIR="${ROOT_DIR}/secrets"
SSH_KEY_PATH="${SECRETS_DIR}/do_ssh_key"
SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"

DO_TF_ENV_DEFAULT="do-prod"
DO_REGION_DEFAULT="nyc1"
DO_SIZE_DEFAULT="s-1vcpu-2gb"
SSH_ALLOWED_CIDRS_DEFAULT='["0.0.0.0/0"]'
OPENCLAW_PORT_DEFAULT="18789"
DO_PROJECT_NAME_DEFAULT="openclaw"
DEPLOY_REF_DEFAULT="openclaw-deploy"
AUTO_SYNC_DEPLOY_REPO_DEFAULT="true"

DO_TF_ENV=""
DO_REGION=""
DO_SIZE=""
SSH_ALLOWED_CIDRS=""
OPENCLAW_PORT=""
REPO_URL=""
DO_PROJECT_NAME=""
DEPLOY_REF=""
AUTO_SYNC_DEPLOY_REPO=""

DO_TOKEN=""
OPENCLAW_GATEWAY_TOKEN=""
OPENAI_API_KEY=""
TELEGRAM_BOT_TOKEN=""

TF_DIR=""
SERVER_IP=""
TF_VAR_ARGS=()
SSH_OPTS=()

die() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

usage() {
  cat <<'EOF'
Usage:
  ./do.sh install [--to <REF>]
  ./do.sh update --to <REF>
  ./do.sh rollback --previous
  ./do.sh rollback --to <REF>
  ./do.sh status
  ./do.sh logs [--follow]
  ./do.sh tunnel
  ./do.sh destroy

Examples:
  ./do.sh install
  ./do.sh install --to v1.0.0
  ./do.sh update --to v1.1.0
  ./do.sh rollback --previous
  ./do.sh tunnel
EOF
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

load_file_if_exists() {
  local file_path="$1"
  if [[ -f "${file_path}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${file_path}"
    set +a
  fi
}

require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Missing ${CONFIG_FILE}. Create it from ${CONFIG_EXAMPLE_FILE}."
  load_file_if_exists "${CONFIG_FILE}"

  : "${DO_TF_ENV:=${DO_TF_ENV_DEFAULT}}"
  : "${DO_REGION:=${DO_REGION_DEFAULT}}"
  : "${DO_SIZE:=${DO_SIZE_DEFAULT}}"
  : "${SSH_ALLOWED_CIDRS:=${SSH_ALLOWED_CIDRS_DEFAULT}}"
  : "${OPENCLAW_PORT:=${OPENCLAW_PORT_DEFAULT}}"
  : "${DO_PROJECT_NAME:=${DO_PROJECT_NAME_DEFAULT}}"
  : "${DEPLOY_REF:=${DEPLOY_REF_DEFAULT}}"
  : "${AUTO_SYNC_DEPLOY_REPO:=${AUTO_SYNC_DEPLOY_REPO_DEFAULT}}"

  if [[ -z "${REPO_URL:-}" ]]; then
    REPO_URL="$(git -C "${ROOT_DIR}" config --get remote.origin.url || true)"
  fi
  [[ -n "${REPO_URL}" ]] || die "REPO_URL is empty in ${CONFIG_FILE} and no git origin URL was found."

  TF_DIR="${ROOT_DIR}/infra/terraform/envs/${DO_TF_ENV}"
  [[ -d "${TF_DIR}" ]] || die "Terraform environment not found: ${TF_DIR}"

  TF_VAR_ARGS=(
    -var "project_name=${DO_PROJECT_NAME}"
    -var "region=${DO_REGION}"
    -var "size=${DO_SIZE}"
    -var "ssh_allowed_cidrs=${SSH_ALLOWED_CIDRS}"
    -var "ssh_public_key_path=${SSH_PUB_KEY_PATH}"
  )
}

load_secrets() {
  load_file_if_exists "${SECRETS_FILE}"
}

persist_secrets() {
  mkdir -p "${SECRETS_DIR}"
  chmod 700 "${SECRETS_DIR}"
  {
    printf "DO_TOKEN=%q\n" "${DO_TOKEN}"
    printf "OPENCLAW_GATEWAY_TOKEN=%q\n" "${OPENCLAW_GATEWAY_TOKEN}"
    printf "OPENAI_API_KEY=%q\n" "${OPENAI_API_KEY}"
    printf "TELEGRAM_BOT_TOKEN=%q\n" "${TELEGRAM_BOT_TOKEN}"
  } >"${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
}

prompt_secret() {
  local var_name="$1"
  local prompt="$2"
  local optional="${3:-false}"
  local current_value
  current_value="${!var_name:-}"
  if [[ -n "${current_value}" ]]; then
    return 0
  fi

  local entered=""
  if [[ "${optional}" == "true" ]]; then
    read -r -s -p "${prompt} (optional, press Enter to skip): " entered
    echo
  else
    while [[ -z "${entered}" ]]; do
      read -r -s -p "${prompt}: " entered
      echo
    done
  fi
  printf -v "${var_name}" "%s" "${entered}"
}

ensure_install_secrets() {
  mkdir -p "${SECRETS_DIR}"
  chmod 700 "${SECRETS_DIR}"
  load_secrets

  local needs_prompt=false
  [[ -n "${DO_TOKEN:-}" ]] || needs_prompt=true
  [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]] || needs_prompt=true
  [[ -n "${OPENAI_API_KEY:-}" ]] || needs_prompt=true

  if [[ "${needs_prompt}" == "true" ]]; then
    info "Missing values in ${SECRETS_FILE}. Prompting once for required secrets."
    prompt_secret DO_TOKEN "Enter DigitalOcean API token (DO_TOKEN)"
    prompt_secret OPENCLAW_GATEWAY_TOKEN "Enter OPENCLAW_GATEWAY_TOKEN"
    prompt_secret OPENAI_API_KEY "Enter OPENAI_API_KEY"
    prompt_secret TELEGRAM_BOT_TOKEN "Enter TELEGRAM_BOT_TOKEN" true
    persist_secrets
  fi

  [[ -n "${DO_TOKEN:-}" ]] || die "DO_TOKEN is required."
  [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]] || die "OPENCLAW_GATEWAY_TOKEN is required."
  [[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY is required."
}

ensure_destroy_secrets() {
  load_secrets
  if [[ -z "${DO_TOKEN:-}" ]]; then
    info "DO_TOKEN is missing in ${SECRETS_FILE}. Prompting."
    prompt_secret DO_TOKEN "Enter DigitalOcean API token (DO_TOKEN)"
    persist_secrets
  fi
  [[ -n "${DO_TOKEN:-}" ]] || die "DO_TOKEN is required for destroy."
}

ensure_ssh_keypair() {
  mkdir -p "${SECRETS_DIR}"
  chmod 700 "${SECRETS_DIR}"
  if [[ ! -f "${SSH_KEY_PATH}" || ! -f "${SSH_PUB_KEY_PATH}" ]]; then
    rm -f "${SSH_KEY_PATH}" "${SSH_PUB_KEY_PATH}"
    info "Generating SSH keypair in ${SECRETS_DIR}"
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_PATH}" >/dev/null
  fi
  chmod 600 "${SSH_KEY_PATH}"
  chmod 644 "${SSH_PUB_KEY_PATH}"
}

require_existing_ssh_keypair() {
  [[ -f "${SSH_KEY_PATH}" && -f "${SSH_PUB_KEY_PATH}" ]] || {
    die "Missing ${SSH_KEY_PATH} or ${SSH_PUB_KEY_PATH}. Run ./do.sh install first."
  }
}

init_ssh_opts() {
  SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o IdentitiesOnly=yes
    -i "${SSH_KEY_PATH}"
  )
}

is_true() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

verify_ref_in_repo_url() {
  local ref="$1"
  if git ls-remote --exit-code "${REPO_URL}" "refs/heads/${ref}" "refs/tags/${ref}" "${ref}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${ref}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    if git ls-remote "${REPO_URL}" | awk '{print $1}' | grep -Eiq "^${ref}"; then
      return 0
    fi
  fi

  die "Ref '${ref}' was not found in REPO_URL='${REPO_URL}'."
}

repo_has_tag() {
  local ref="$1"
  git ls-remote --exit-code "${REPO_URL}" "refs/tags/${ref}" >/dev/null 2>&1
}

repo_has_branch() {
  local ref="$1"
  git ls-remote --exit-code "${REPO_URL}" "refs/heads/${ref}" >/dev/null 2>&1
}

publish_local_snapshot_to_repo_ref() {
  local ref="$1"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  git -C "${tmp_dir}" init -q
  git -C "${tmp_dir}" config user.name "OpenClaw Deploy Bot"
  git -C "${tmp_dir}" config user.email "openclaw-deploy@localhost"
  git -C "${tmp_dir}" remote add origin "${REPO_URL}"

  if git -C "${tmp_dir}" fetch --depth=1 origin "refs/heads/${ref}" >/dev/null 2>&1; then
    git -C "${tmp_dir}" checkout -q -B "${ref}" FETCH_HEAD
  else
    git -C "${tmp_dir}" checkout -q -B "${ref}"
  fi

  find "${tmp_dir}" -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +

  rsync -a --delete \
    --exclude ".git/" \
    --exclude ".DS_Store" \
    --exclude "config/do.env" \
    --exclude "secrets/do.env" \
    --exclude "secrets/do_ssh_key" \
    --exclude "secrets/do_ssh_key.pub" \
    --exclude ".terraform/" \
    --exclude "*.tfstate" \
    --exclude "*.tfstate.*" \
    "${ROOT_DIR}/" "${tmp_dir}/"

  git -C "${tmp_dir}" add -A
  if git -C "${tmp_dir}" diff --cached --quiet; then
    info "Deploy repository is already up to date for ref '${ref}'."
  else
    git -C "${tmp_dir}" commit -q -m "Sync deployment template $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  git -C "${tmp_dir}" push -q origin "HEAD:refs/heads/${ref}"
  trap - RETURN
  rm -rf "${tmp_dir}"
}

ensure_deploy_ref_available() {
  local ref="$1"
  if is_true "${AUTO_SYNC_DEPLOY_REPO}"; then
    if [[ "${ref}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
      info "Ref '${ref}' looks like commit SHA; skipping auto-sync and using remote ref lookup."
    elif repo_has_tag "${ref}" && ! repo_has_branch "${ref}"; then
      info "Ref '${ref}' exists as tag in ${REPO_URL}; using tag as-is."
    else
      info "Syncing local template to ${REPO_URL} (branch: ${ref})"
      publish_local_snapshot_to_repo_ref "${ref}"
    fi
  fi
  verify_ref_in_repo_url "${ref}"
}

prepare_terraform_auth() {
  [[ -n "${DO_TOKEN:-}" ]] || die "DO_TOKEN is required."
  export DIGITALOCEAN_TOKEN="${DO_TOKEN}"
}

terraform_init() {
  terraform -chdir="${TF_DIR}" init -input=false
}

terraform_apply() {
  terraform -chdir="${TF_DIR}" apply -input=false -auto-approve "${TF_VAR_ARGS[@]}"
}

terraform_destroy() {
  terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve "${TF_VAR_ARGS[@]}"
}

get_server_ip() {
  local ip
  ip="$(terraform -chdir="${TF_DIR}" output -raw server_ip 2>/dev/null || true)"
  [[ -n "${ip}" ]] || die "Unable to resolve server IP from Terraform output. Run ./do.sh install first."
  printf "%s\n" "${ip}"
}

wait_for_root_ssh() {
  local attempts=40
  local delay=5
  local i
  for ((i = 1; i <= attempts; i++)); do
    if ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "true" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done
  die "SSH to root@${SERVER_IP} did not become ready in time."
}

ssh_root() {
  ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "$@"
}

scp_to_root() {
  local local_file="$1"
  local remote_path="$2"
  scp "${SSH_OPTS[@]}" "${local_file}" "root@${SERVER_IP}:${remote_path}"
}

resolve_default_ref() {
  local exact_tag
  exact_tag="$(git -C "${ROOT_DIR}" describe --tags --exact-match 2>/dev/null || true)"
  if [[ -n "${exact_tag}" ]]; then
    printf "%s\n" "${exact_tag}"
    return 0
  fi

  local branch_name
  branch_name="$(git -C "${ROOT_DIR}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -n "${branch_name}" ]]; then
    printf "%s\n" "${branch_name}"
    return 0
  fi

  git -C "${ROOT_DIR}" rev-parse HEAD
}

create_runtime_env_file() {
  local file_path="$1"
  {
    printf "OPENCLAW_GATEWAY_TOKEN=%q\n" "${OPENCLAW_GATEWAY_TOKEN}"
    printf "OPENAI_API_KEY=%q\n" "${OPENAI_API_KEY}"
    printf "OPENCLAW_PORT=%q\n" "${OPENCLAW_PORT}"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
      printf "TELEGRAM_BOT_TOKEN=%q\n" "${TELEGRAM_BOT_TOKEN}"
    fi
  } >"${file_path}"
  chmod 600 "${file_path}"
}

run_remote_script() {
  local script_name="$1"
  shift
  local cmd="/home/openclaw/openclaw-deploy/scripts/do/${script_name}"
  ssh_root "bash ${cmd} $*"
}

print_dashboard_url() {
  info "Tokenized dashboard URL (open locally while ./do.sh tunnel is running)"
  if ! ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-dashboard-url.sh"; then
    info "Could not render dashboard URL automatically."
    info "Retry with: ssh ${SSH_OPTS[*]} root@${SERVER_IP} 'bash /home/openclaw/openclaw-deploy/scripts/do/remote-dashboard-url.sh'"
  fi
}

cmd_install() {
  local target_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift
        [[ $# -gt 0 ]] || die "--to requires a value"
        target_ref="$1"
        ;;
      *)
        die "Unknown install option: $1"
        ;;
    esac
    shift
  done

  require_cmd terraform
  require_cmd ssh
  require_cmd scp
  require_cmd ssh-keygen
  require_cmd git
  require_cmd rsync

  require_config
  if [[ -z "${target_ref}" ]]; then
    target_ref="${DEPLOY_REF}"
  fi
  if [[ -z "${target_ref}" ]]; then
    target_ref="$(resolve_default_ref)"
  fi
  ensure_deploy_ref_available "${target_ref}"
  ensure_install_secrets
  ensure_ssh_keypair
  prepare_terraform_auth

  info "Terraform init (${DO_TF_ENV})"
  terraform_init
  info "Terraform apply (${DO_TF_ENV})"
  terraform_apply

  SERVER_IP="$(get_server_ip)"
  init_ssh_opts
  info "Waiting for SSH on ${SERVER_IP}"
  wait_for_root_ssh

  local runtime_env_tmp
  runtime_env_tmp="$(mktemp)"
  create_runtime_env_file "${runtime_env_tmp}"
  scp_to_root "${runtime_env_tmp}" "/root/openclaw-runtime.env"
  rm -f "${runtime_env_tmp}"

  info "Running remote bootstrap"
  ssh_root "REPO_URL=$(printf '%q' "${REPO_URL}") DEPLOY_REF=$(printf '%q' "${target_ref}") OPENCLAW_PORT=$(printf '%q' "${OPENCLAW_PORT}") RUNTIME_ENV_PATH=/root/openclaw-runtime.env bash -s" <"${ROOT_DIR}/scripts/do/remote-bootstrap.sh"

  info "Running remote apply and smoke checks"
  ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-apply.sh --ref $(printf '%q' "${target_ref}")"
  print_dashboard_url

  info "Install complete."
  info "Server IP: ${SERVER_IP}"
  info "Open tunnel with: ./do.sh tunnel"
}

cmd_update() {
  local target_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift
        [[ $# -gt 0 ]] || die "--to requires a value"
        target_ref="$1"
        ;;
      *)
        die "Unknown update option: $1"
        ;;
    esac
    shift
  done
  [[ -n "${target_ref}" ]] || die "Usage: ./do.sh update --to <REF>"

  require_cmd terraform
  require_cmd ssh
  require_cmd git
  require_cmd rsync
  require_config
  ensure_deploy_ref_available "${target_ref}"
  require_existing_ssh_keypair
  terraform_init
  SERVER_IP="$(get_server_ip)"
  init_ssh_opts

  info "Applying ref ${target_ref} on ${SERVER_IP}"
  ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-apply.sh --ref $(printf '%q' "${target_ref}")"
  print_dashboard_url
}

cmd_rollback() {
  local use_previous=false
  local target_ref=""

  if [[ $# -eq 0 ]]; then
    use_previous=true
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --previous)
        use_previous=true
        ;;
      --to)
        shift
        [[ $# -gt 0 ]] || die "--to requires a value"
        target_ref="$1"
        ;;
      *)
        die "Unknown rollback option: $1"
        ;;
    esac
    shift
  done

  if [[ "${use_previous}" == "true" && -n "${target_ref}" ]]; then
    die "Use either --previous or --to <REF>, not both."
  fi

  require_cmd terraform
  require_cmd ssh
  require_config
  require_existing_ssh_keypair
  terraform_init
  SERVER_IP="$(get_server_ip)"
  init_ssh_opts

  if [[ "${use_previous}" == "true" ]]; then
    info "Rolling back to previous good ref on ${SERVER_IP}"
    ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-rollback.sh --previous"
  else
    info "Rolling back to ${target_ref} on ${SERVER_IP}"
    ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-rollback.sh --to $(printf '%q' "${target_ref}")"
  fi
  print_dashboard_url
}

cmd_status() {
  require_cmd terraform
  require_cmd ssh
  require_config
  require_existing_ssh_keypair
  terraform_init
  SERVER_IP="$(get_server_ip)"
  init_ssh_opts
  ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-status.sh"
}

cmd_logs() {
  local follow=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow)
        follow=true
        ;;
      *)
        die "Unknown logs option: $1"
        ;;
    esac
    shift
  done

  require_cmd terraform
  require_cmd ssh
  require_config
  require_existing_ssh_keypair
  terraform_init
  SERVER_IP="$(get_server_ip)"
  init_ssh_opts

  if [[ "${follow}" == "true" ]]; then
    ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-logs.sh --follow"
  else
    ssh_root "bash /home/openclaw/openclaw-deploy/scripts/do/remote-logs.sh"
  fi
}

cmd_tunnel() {
  require_cmd terraform
  require_cmd ssh
  require_config
  require_existing_ssh_keypair
  terraform_init
  SERVER_IP="$(get_server_ip)"
  init_ssh_opts

  info "Opening SSH tunnel: localhost:${OPENCLAW_PORT} -> ${SERVER_IP}:127.0.0.1:${OPENCLAW_PORT}"
  exec ssh "${SSH_OPTS[@]}" -N -L "${OPENCLAW_PORT}:127.0.0.1:${OPENCLAW_PORT}" "openclaw@${SERVER_IP}"
}

cmd_destroy() {
  require_cmd terraform
  require_config
  ensure_destroy_secrets
  ensure_ssh_keypair
  prepare_terraform_auth

  info "Terraform init (${DO_TF_ENV})"
  terraform_init
  info "Terraform destroy (${DO_TF_ENV})"
  terraform_destroy
}

main() {
  local command="${1:-}"
  if [[ -z "${command}" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "${command}" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    rollback) cmd_rollback "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    tunnel) cmd_tunnel "$@" ;;
    destroy) cmd_destroy "$@" ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      die "Unknown command: ${command}"
      ;;
  esac
}

main "$@"
