#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="${1:-/var/log/nginx/africair.access.json}"

[[ -r "${LOG_FILE}" ]] || {
  echo "Usage: $0 [logfile]" >&2
  echo "Cannot read: ${LOG_FILE}" >&2
  exit 1
}

echo "Top 10 client IPs"
jq -r '.remote_addr' "${LOG_FILE}" |
  sort | uniq -c | sort -rn |
  awk 'NR <= 10 { printf "%s %s\n", $1, $2 }'

echo
echo "Requests by status class"
jq -r '(.status | tostring | .[0:1]) + "xx"' "${LOG_FILE}" |
  sort | uniq -c | sort |
  awk '{ printf "%s: %s\n", $2, $1 }'

echo
echo "Top 10 requested paths"
jq -r '.request | split(" ")[1] // "-"' "${LOG_FILE}" |
  sort | uniq -c | sort -rn |
  awk 'NR <= 10 { printf "%s %s\n", $1, $2 }'

echo
echo "Requests per minute for the last hour"
jq -r '
  select(
    (.time | sub("\\+00:00$"; "Z") | fromdateiso8601) >= (now - 3600)
  )
  | .time[0:16]
' "${LOG_FILE}" |
  sort | uniq -c |
  awk '{ printf "%s %s\n", $2, $1 }'
