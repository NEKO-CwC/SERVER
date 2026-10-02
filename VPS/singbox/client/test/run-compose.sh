#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../compose.test.yml"
COMPOSE=(docker compose -f "${COMPOSE_FILE}")

cleanup() {
  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup EXIT

"${COMPOSE[@]}" build client
"${COMPOSE[@]}" up -d --wait subscription client
"${COMPOSE[@]}" exec -T client bash /workspace/test/verify.sh http://subscription:8080/config.json
