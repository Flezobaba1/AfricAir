#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run with sudo." >&2
  exit 1
fi

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <africair-api-<sha>.tar.gz>" >&2
  exit 2
fi

API_ROOT="/opt/africair/api"
RELEASES="${API_ROOT}/releases"
CURRENT="${API_ROOT}/current"
PREVIOUS="${API_ROOT}/previous"
ARTIFACT="$1"
CHECKSUM="${ARTIFACT}.sha256"

[[ -f "${ARTIFACT}" ]] || { echo "ERROR: API artifact not found." >&2; exit 1; }
[[ -f "${CHECKSUM}" ]] || { echo "ERROR: API checksum file not found." >&2; exit 1; }

ARTIFACT="$(realpath "${ARTIFACT}")"
(
  cd "$(dirname "${ARTIFACT}")"
  sha256sum -c "$(basename "${CHECKSUM}")"
)

SHORT_SHA="$(basename "${ARTIFACT}" | sed -E 's/^africair-api-([0-9a-f]+)\.tar\.gz$/\1/')"
[[ "${SHORT_SHA}" =~ ^[0-9a-f]+$ ]] || { echo "ERROR: invalid API artifact name." >&2; exit 1; }

install -d -m 0755 -o africair -g africair "${RELEASES}"

RELEASE_NAME="$(date -u '+%Y%m%dT%H%M%SZ')-${SHORT_SHA}"
RELEASE_DIR="${RELEASES}/${RELEASE_NAME}"
INCOMING="$(mktemp -d "${RELEASES}/.incoming.XXXXXX")"

cleanup() {
  if [[ -d "${INCOMING:-}" ]]; then
    rm -rf -- "${INCOMING}"
  fi
  return 0
}
trap cleanup EXIT

tar -xzf "${ARTIFACT}" -C "${INCOMING}"
[[ -f "${INCOMING}/dist/index.js" ]] || { echo "ERROR: API entry point missing." >&2; exit 1; }
[[ -f "${INCOMING}/dist/migrate.js" ]] || { echo "ERROR: API migration runner missing." >&2; exit 1; }
[[ -d "${INCOMING}/migrations" ]] || { echo "ERROR: API migrations missing." >&2; exit 1; }
[[ -d "${INCOMING}/node_modules" ]] || { echo "ERROR: production dependencies missing." >&2; exit 1; }

mv "${INCOMING}" "${RELEASE_DIR}"
INCOMING=""
chown -R africair:africair "${RELEASE_DIR}"
chmod -R a+rX "${RELEASE_DIR}"

PREVIOUS_DIR=""
if [[ -L "${CURRENT}" ]]; then
  PREVIOUS_DIR="$(readlink -f "${CURRENT}")"
fi

switch_link() {
  local target="$1"
  local link="$2"
  local temporary="${API_ROOT}/.$(basename "${link}").$$"

  ln -sfn "${target}" "${temporary}"
  mv -Tf "${temporary}" "${link}"
}

rollback_api() {
  if [[ -n "${PREVIOUS_DIR}" ]]; then
    echo "API health check failed; restoring previous release."
    switch_link "releases/$(basename "${PREVIOUS_DIR}")" "${CURRENT}"
    systemctl restart africair-api || true
  else
    echo "ERROR: first API release failed; no previous release exists." >&2
    systemctl stop africair-api || true
  fi
}

DATABASE_URL_FILE="/etc/africair/secrets/database_url" \
  node "${RELEASE_DIR}/dist/migrate.js"

if [[ -n "${PREVIOUS_DIR}" ]]; then
  switch_link "releases/$(basename "${PREVIOUS_DIR}")" "${PREVIOUS}"
fi
switch_link "releases/${RELEASE_NAME}" "${CURRENT}"

systemctl daemon-reload
systemctl restart africair-api

healthy=false
for _ in {1..15}; do
  if curl --fail --silent --show-error --max-time 3 http://127.0.0.1:4000/api/readyz >/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done

if [[ "${healthy}" != true ]]; then
  rollback_api
  exit 1
fi

find "${RELEASES}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
  sort -rn |
  tail -n +6 |
  cut -d' ' -f2- |
  while IFS= read -r old_release; do
    [[ -n "${old_release}" ]] || continue
    rm -rf -- "${old_release}"
  done

echo "API deployment complete: ${RELEASE_NAME}"
