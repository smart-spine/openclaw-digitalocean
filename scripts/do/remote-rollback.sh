#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
DEPLOY_DIR="${OPENCLAW_HOME}/openclaw-deploy"
DEPLOY_STATE_FILE="/home/${OPENCLAW_USER}/.openclaw/deploy-state.json"

USE_PREVIOUS=false
TARGET_REF=""

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  remote-rollback.sh --previous
  remote-rollback.sh --to <REF>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --previous)
      USE_PREVIOUS=true
      ;;
    --to|--ref)
      shift
      [[ $# -gt 0 ]] || die "$1 requires a value"
      TARGET_REF="$1"
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

if [[ "${USE_PREVIOUS}" == "true" && -n "${TARGET_REF}" ]]; then
  die "Use either --previous or --to <REF>, not both."
fi

if [[ "${USE_PREVIOUS}" == "true" ]]; then
  [[ -f "${DEPLOY_STATE_FILE}" ]] || die "Deploy state not found: ${DEPLOY_STATE_FILE}"
  TARGET_REF="$(jq -r '.last_good_ref // empty' "${DEPLOY_STATE_FILE}")"
  [[ -n "${TARGET_REF}" ]] || die "last_good_ref is empty in ${DEPLOY_STATE_FILE}"
fi

[[ -n "${TARGET_REF}" ]] || die "No rollback target provided."
[[ -f "${DEPLOY_DIR}/scripts/do/remote-apply.sh" ]] || die "remote-apply.sh not found in ${DEPLOY_DIR}"

echo "==> Rolling back to ${TARGET_REF}"
bash "${DEPLOY_DIR}/scripts/do/remote-apply.sh" --ref "${TARGET_REF}"
