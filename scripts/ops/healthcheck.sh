#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/africair"
STATE_FILE="${STATE_DIR}/healthcheck-failures"
URL="http://127.0.0.1/healthz"

install -d -m 0755 "${STATE_DIR}"
failures=0
[[ -f "${STATE_FILE}" ]] && failures="$(cat "${STATE_FILE}")"

if curl --fail --silent --show-error --max-time 5 "${URL}" >/dev/null; then
  printf '0\n' > "${STATE_FILE}"
  logger -t africair-health "OK: ${URL} responded successfully"
  exit 0
fi

failures=$((failures + 1))
printf '%s\n' "${failures}" > "${STATE_FILE}"
logger -t africair-health "FAILURE ${failures}/3: ${URL} did not respond"

if (( failures >= 3 )); then
  logger -t africair-health "WARNING: three consecutive failures; reloading nginx"
  nginx -t && systemctl reload nginx
  printf '0\n' > "${STATE_FILE}"
fi

exit 1
