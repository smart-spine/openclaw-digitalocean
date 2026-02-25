#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
echo "Run locally:"
echo "ssh -N -L ${OPENCLAW_PORT}:127.0.0.1:${OPENCLAW_PORT} openclaw@<SERVER_IP> -i secrets/do_ssh_key -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"
