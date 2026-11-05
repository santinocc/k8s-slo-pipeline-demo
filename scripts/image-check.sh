#!/usr/bin/env bash
# Prints the size and user of each image and fails if an image is 200 MB or
# larger, or does not run as the non-root UID 10001.
# Usage: scripts/image-check.sh IMAGE:TAG [IMAGE:TAG ...]
set -euo pipefail

MAX_BYTES="${MAX_BYTES:-200000000}"
EXPECTED_USER="${EXPECTED_USER:-10001:10001}"
status=0

for image in "$@"; do
  size=$(docker image inspect "$image" --format '{{.Size}}')
  user=$(docker image inspect "$image" --format '{{.Config.User}}')
  mb=$(awk -v s="$size" 'BEGIN { printf "%.1f", s / 1000 / 1000 }')
  if [ "$size" -lt "$MAX_BYTES" ] && [ "$user" = "$EXPECTED_USER" ]; then
    echo "PASS $image ${mb} MB user=$user"
  else
    echo "FAIL $image ${mb} MB user=$user (want < $((MAX_BYTES / 1000000)) MB and user=$EXPECTED_USER)"
    status=1
  fi
done

exit "$status"
