#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -f "${SCRIPT_DIR}/../compose.test.yml")
cleanup() { "${COMPOSE[@]}" down --volumes --remove-orphans; }
trap cleanup EXIT
"${COMPOSE[@]}" build server
"${COMPOSE[@]}" up -d --wait subscription server
"${COMPOSE[@]}" exec -T server bash /repo/VPS/singbox/server/test/verify.sh
