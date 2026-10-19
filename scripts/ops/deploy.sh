#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run with sudo." >&2
  exit 1
fi

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <artifact.tar.gz>" >&2
  exit 2
fi

APP_ROOT="/opt/africair"
RELEASES="${APP_ROOT}/releases"
CURRENT="${APP_ROOT}/current"
PREVIOUS="${APP_ROOT}/previous"
ARTIFACT="$(realpath "$1")"
CHECKSUM="${ARTIFACT}.sha256"

[[ -f "${ARTIFACT}" ]] || { echo "ERROR: artifact not found." >&2; exit 1; }
[[ -f "${CHECKSUM}" ]] || { echo "ERROR: checksum file not found." >&2; exit 1; }

(
  cd "$(dirname "${ARTIFACT}")"
  sha256sum -c "$(basename "${CHECKSUM}")"
)

SHORT_SHA="$(basename "${ARTIFACT}" | sed -E 's/^africair-([0-9a-f]+)\.tar\.gz$/\1/')"
[[ "${SHORT_SHA}" =~ ^[0-9a-f]+$ ]] || { echo "ERROR: invalid artifact name." >&2; exit 1; }

RELEASE_NAME="$(date -u '+%Y%m%dT%H%M%SZ')-${SHORT_SHA}"
RELEASE_DIR="${RELEASES}/${RELEASE_NAME}"
INCOMING="$(mktemp -d "${RELEASES}/.incoming.XXXXXX")"

cleanup() {
  [[ -d "${INCOMING:-}" ]] && rm -rf -- "${INCOMING}"
}
trap cleanup EXIT

tar -xzf "${ARTIFACT}" -C "${INCOMING}"
[[ -f "${INCOMING}/version.json" ]] || { echo "ERROR: version.json missing." >&2; exit 1; }

EXPECTED_COMMIT="$(jq -er '.commit' "${INCOMING}/version.json")"
[[ "${EXPECTED_COMMIT}" == "${SHORT_SHA}"* ]] || {
  echo "ERROR: artifact filename and version commit do not match." >&2
  exit 1
}

mv "${INCOMING}" "${RELEASE_DIR}"
INCOMING=""
chown -R africair:africair "${RELEASE_DIR}"
chmod -R a+rX "${RELEASE_DIR}"
chmod -R a+rX "${RELEASE_DIR}"

PREVIOUS_DIR="$(readlink -f "${CURRENT}")"

switch_link() {
  local target="$1"
  local link="$2"
  local temporary="${APP_ROOT}/.$(basename "${link}").$$"

  ln -sfn "${target}" "${temporary}"
  mv -Tf "${temporary}" "${link}"
}

# Create links relative to /opt/africair, then atomically replace current.
switch_link "releases/${RELEASE_NAME}" "${CURRENT}"
switch_link "releases/$(basename "${PREVIOUS_DIR}")" "${PREVIOUS}"

rollback_deploy() {
  echo "Deployment health check failed; restoring previous release."
  switch_link "releases/$(basename "${PREVIOUS_DIR}")" "${CURRENT}"
  nginx -t && systemctl reload nginx
}

if ! nginx -t; then
  rollback_deploy
  exit 1
fi

systemctl reload nginx

if ! curl --fail --silent --show-error --max-time 5 http://127.0.0.1/healthz >/dev/null; then
  rollback_deploy
  exit 1
fi

SERVED_COMMIT="$(curl --fail --silent --show-error --max-time 5 http://127.0.0.1/version.json | jq -er '.commit')" || {
  rollback_deploy
  exit 1
}

if [[ "${SERVED_COMMIT}" != "${EXPECTED_COMMIT}" ]]; then
  echo "ERROR: served commit does not match deployed commit." >&2
  rollback_deploy
  exit 1
fi
mapfile -t OLD_RELEASES < <(
  find "${RELEASES}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
    sort -rn |
    tail -n +6 |
    cut -d' ' -f2-
) || true


for old_release in "${OLD_RELEASES[@]}"; do
  rm -rf -- "${old_release}"
done

