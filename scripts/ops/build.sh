#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/ops/build.sh <git-ref>

Builds an AfricAir static-site artifact from a branch, tag, or commit SHA.

Exit codes:
  10  Clone, fetch, or checkout failure
  20  Dependency installation failure
  30  TypeScript check or unit-test failure
  40  Front-end build, metadata, or packaging failure
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$#" -ne 1 ]]; then
  usage >&2
  exit 2
fi

REF="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}/../.." rev-parse --show-toplevel)" || {
  echo "ERROR: build.sh must be run from an AfricAir Git working tree." >&2
  exit 10
}
REPO_URL="$(git -C "${REPO_ROOT}" remote get-url origin)" || {
  echo "ERROR: no origin remote is configured." >&2
  exit 10
}

TEMP_DIR="$(mktemp -d -t africair-build.XXXXXX)"
WORKTREE="${TEMP_DIR}/repo"
ARTIFACT_DIR="${REPO_ROOT}/artifacts"

cleanup() {
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

run_stage() {
  local code="$1"
  local label="$2"
  shift 2

  if ! "$@"; then
    echo "ERROR: ${label} failed." >&2
    exit "${code}"
  fi
}

run_stage 10 "Repository clone" git clone --no-checkout "${REPO_URL}" "${WORKTREE}"
run_stage 10 "Git checkout" git -C "${WORKTREE}" checkout --detach "${REF}"

if ! (
  cd "${WORKTREE}"
  corepack enable
  pnpm install --frozen-lockfile
); then
  echo "ERROR: dependency installation failed." >&2
  exit 20
fi

if ! (
  cd "${WORKTREE}"
  pnpm check
  pnpm test
); then
  echo "ERROR: quality checks or tests failed." >&2
  exit 30
fi

if ! (
  cd "${WORKTREE}"
  pnpm build
  pnpm build:api
); then
  echo "ERROR: front-end build failed." >&2
  exit 40
fi

COMMIT="$(git -C "${WORKTREE}" rev-parse HEAD)"
SHORT_SHA="$(git -C "${WORKTREE}" rev-parse --short=12 HEAD)"
BUILT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
BUILT_BY="$(id -un)"
NODE_VERSION="$(node --version)"

if ! jq -n \
  --arg commit "${COMMIT}" \
  --arg ref "${REF}" \
  --arg builtAt "${BUILT_AT}" \
  --arg builtBy "${BUILT_BY}" \
  --arg nodeVersion "${NODE_VERSION}" \
  '{commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion}' \
  > "${WORKTREE}/dist/version.json"; then
  echo "ERROR: version metadata generation failed." >&2
  exit 40
fi

mkdir -p "${ARTIFACT_DIR}"
ARTIFACT="${ARTIFACT_DIR}/africair-${SHORT_SHA}.tar.gz"
CHECKSUM="${ARTIFACT}.sha256"

if ! tar -C "${WORKTREE}/dist" -czf "${ARTIFACT}" . ||
  ! (cd "${ARTIFACT_DIR}" && sha256sum "$(basename "${ARTIFACT}")" > "$(basename "${CHECKSUM}")"); then
  echo "ERROR: artifact packaging failed." >&2
  exit 40
fi
API_STAGE="${TEMP_DIR}/api-package"
API_ARTIFACT="${ARTIFACT_DIR}/africair-api-${SHORT_SHA}.tar.gz"
API_CHECKSUM="${API_ARTIFACT}.sha256"

if ! (
  cd "${WORKTREE}"
  pnpm --filter @africair/api deploy --prod --legacy "${API_STAGE}"
  rm -rf "${API_STAGE}/migrations"
  cp -a server/migrations "${API_STAGE}/migrations"
  [[ -f "${API_STAGE}/dist/index.js" ]]
  [[ -d "${API_STAGE}/node_modules" ]]
); then
  echo "ERROR: API packaging failed." >&2
  exit 40
fi

if ! tar -C "${API_STAGE}" -czf "${API_ARTIFACT}" . ||
  ! (cd "${ARTIFACT_DIR}" && sha256sum "$(basename "${API_ARTIFACT}")" > "$(basename "${API_CHECKSUM}")"); then
  echo "ERROR: API artifact creation failed." >&2
  exit 40
fi
echo "Build complete"
echo "Artifact: ${ARTIFACT}"
echo "Checksum: ${CHECKSUM}"
echo "API artifact: ${API_ARTIFACT}"
echo "API checksum: ${API_CHECKSUM}"

