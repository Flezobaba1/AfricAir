#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 <dist-dir> <bucket> <distribution-id>" >&2
  exit 2
fi

DIST_DIR="$(cd "$1" && pwd)"
BUCKET="$2"
DISTRIBUTION_ID="$3"
DESTINATION="s3://${BUCKET}"

[[ -d "${DIST_DIR}/assets" ]] || { echo "ERROR: assets directory missing." >&2; exit 1; }
[[ -f "${DIST_DIR}/index.html" ]] || { echo "ERROR: index.html missing." >&2; exit 1; }
[[ -f "${DIST_DIR}/version.json" ]] || { echo "ERROR: version.json missing." >&2; exit 1; }

# Publish fingerprinted assets first. Do not delete old assets yet.
aws s3 sync "${DIST_DIR}/assets/" "${DESTINATION}/assets/" \
  --cache-control "public,max-age=31536000,immutable"

# Publish the mutable entry point and deployment metadata next.
aws s3 cp "${DIST_DIR}/index.html" "${DESTINATION}/index.html" \
  --cache-control "no-cache" \
  --content-type "text/html"

aws s3 cp "${DIST_DIR}/version.json" "${DESTINATION}/version.json" \
  --cache-control "no-cache" \
  --content-type "application/json"

# Only delete stale assets after the new index.html is live.
aws s3 sync "${DIST_DIR}/assets/" "${DESTINATION}/assets/" \
  --delete \
  --cache-control "public,max-age=31536000,immutable"

# Delete other stale top-level files, preserving the just-uploaded entry files.
aws s3 sync "${DIST_DIR}/" "${DESTINATION}/" \
  --delete \
  --exclude "assets/*" \
  --exclude "index.html" \
  --exclude "version.json" \
  --cache-control "no-cache"

# Hashed assets are immutable; invalidate only stable, mutable paths.
aws cloudfront create-invalidation \
  --distribution-id "${DISTRIBUTION_ID}" \
  --paths "/index.html" "/version.json"

echo "Published ${DIST_DIR} to ${DESTINATION}"
