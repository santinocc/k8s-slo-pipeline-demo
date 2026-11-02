#!/usr/bin/env bash
# Sends requests continuously while the API Deployment is restarted, and fails
# if any request does not return 200. Used to verify zero-downtime rollouts.
set -euo pipefail

URL="${URL:-http://localhost:8080/items}"
KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-slo-demo}"
results="$(mktemp)"
trap 'rm -f "$results"' EXIT

(
  while true; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "$URL" >>"$results" || echo "000" >>"$results"
    sleep 0.05
  done
) &
loop_pid=$!

sleep 2
$KUBECTL -n "$NAMESPACE" rollout restart deployment/api
$KUBECTL -n "$NAMESPACE" rollout status deployment/api --timeout=180s
sleep 3
kill "$loop_pid"
wait "$loop_pid" 2>/dev/null || true

total=$(wc -l <"$results" | tr -d ' ')
failed=$(grep -vc '^200$' "$results" || true)
echo "Requests: $total, non-200: $failed"
if [[ "$failed" -gt 0 ]]; then
  sort "$results" | uniq -c
  echo "FAIL: requests failed during the rollout"
  exit 1
fi
echo "PASS: zero failed requests during the rollout"
