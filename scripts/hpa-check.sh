#!/usr/bin/env bash
# Generates load with hey and checks that the HPA scales the API Deployment up
# to at least MIN_PEAK replicas, then back down to its minimum after the load stops.
set -euo pipefail

URL="${URL:-http://localhost:8080/items}"
KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-slo-demo}"
DURATION="${DURATION:-180s}"
CONCURRENCY="${CONCURRENCY:-50}"
MIN_PEAK="${MIN_PEAK:-4}"
SCALE_DOWN_TIMEOUT="${SCALE_DOWN_TIMEOUT:-420}"

replicas() { $KUBECTL -n "$NAMESPACE" get deployment api -o jsonpath='{.status.replicas}'; }
min_replicas=$($KUBECTL -n "$NAMESPACE" get hpa api -o jsonpath='{.spec.minReplicas}')

echo "Load: hey -z $DURATION -c $CONCURRENCY $URL"
hey -z "$DURATION" -c "$CONCURRENCY" "$URL" >/tmp/hey-report.$$ &
hey_pid=$!

peak=0
while kill -0 "$hey_pid" 2>/dev/null; do
  r=$(replicas)
  (( r > peak )) && peak=$r
  echo "$(date +%T) replicas=$r $($KUBECTL -n "$NAMESPACE" get hpa api --no-headers | awk '{print "targets=" $4}')"
  sleep 10
done
grep -E 'Requests/sec|Status code distribution' -A3 /tmp/hey-report.$$ | head -8
rm -f /tmp/hey-report.$$
echo "Peak replicas: $peak"

echo "Waiting up to ${SCALE_DOWN_TIMEOUT}s for scale-down to $min_replicas..."
waited=0
while (( $(replicas) > min_replicas )); do
  if (( waited >= SCALE_DOWN_TIMEOUT )); then
    echo "FAIL: still at $(replicas) replicas after ${SCALE_DOWN_TIMEOUT}s"
    exit 1
  fi
  sleep 15
  waited=$((waited + 15))
  echo "$(date +%T) replicas=$(replicas)"
done

if (( peak < MIN_PEAK )); then
  echo "FAIL: peak $peak is below $MIN_PEAK replicas"
  exit 1
fi
echo "PASS: scaled $min_replicas -> $peak -> $(replicas)"
