#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run with sudo." >&2
  exit 1
fi

APP_ROOT="/opt/africair"
CURRENT="${APP_ROOT}/current"
PREVIOUS="${APP_ROOT}/previous"

[[ -L "${PREVIOUS}" ]] || {
  echo "ERROR: no previous release is available." >&2
  exit 1
}

PREVIOUS_DIR="$(readlink -f "${PREVIOUS}")"
CURRENT_DIR="$(readlink -f "${CURRENT}")"

switch_link() {
  local target="$1"
  local link="$2"
  local temporary="${APP_ROOT}/.$(basename "${link}").$$"

  ln -sfn "${target}" "${temporary}"
  mv -Tf "${temporary}" "${link}"
}

switch_link "releases/$(basename "${PREVIOUS_DIR}")" "${CURRENT}"
switch_link "releases/$(basename "${CURRENT_DIR}")" "${PREVIOUS}"

nginx -t
systemctl reload nginx

curl --fail --silent --show-error http://127.0.0.1/healthz >/dev/null
echo "Rollback complete: $(basename "${PREVIOUS_DIR}") is now current."


