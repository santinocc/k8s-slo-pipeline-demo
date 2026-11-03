#!/usr/bin/env bash
# SLO alert demo: enables /chaos, sends normal plus failing traffic until the
# SLOErrorBudgetBurnFast alert fires, holds it, then stops the errors and waits
# for the alert to clear. Chaos is disabled again on exit.
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-slo-demo}"
API="${API:-http://localhost:8080}"
PROM="${PROM:-http://localhost:9090}"
ALERT="${ALERT:-SLOErrorBudgetBurnFast}"
CHAOS_RATE="${CHAOS_RATE:-0.5}"
HOLD_SECONDS="${HOLD_SECONDS:-120}"   # keep the alert firing this long (for screenshots)
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
k() { $KUBECTL -n "$NAMESPACE" "$@"; }

prom_value() {
  curl -sfG "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print("{:.1%}".format(float(r[0]["value"][1])) if r else "n/a")'
}
alert_state() {
  curl -sf "$PROM/api/v1/alerts" | python3 -c '
import json, sys
alerts = [a for a in json.load(sys.stdin)["data"]["alerts"] if a["labels"]["alertname"] == sys.argv[1]]
print(alerts[0]["state"] if alerts else "inactive")' "$ALERT"
}
report() {
  echo "$(date -u +%T) $ALERT=$(alert_state) error_ratio_5m=$(prom_value 'slo:sli_error:ratio_rate5m') error_ratio_1h=$(prom_value 'slo:sli_error:ratio_rate1h')"
}
wait_for_state() {  # $1 = firing | inactive
  local waited=0
  until [[ "$(alert_state)" == "$1" ]]; do
    (( waited >= TIMEOUT_SECONDS )) && { echo "FAIL: $ALERT not $1 after ${TIMEOUT_SECONDS}s"; exit 1; }
    report; sleep 30; waited=$((waited + 30))
  done
}

pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  echo "Disabling chaos..."
  k set env deployment/api CHAOS_ENABLED- >/dev/null
  k rollout status deployment/api --timeout=180s >/dev/null
}
trap cleanup EXIT

echo "Enabling /chaos on the API Deployment..."
k set env deployment/api CHAOS_ENABLED=true >/dev/null
k rollout status deployment/api --timeout=180s >/dev/null

# About 10 req/s of normal traffic and 10 req/s to /chaos (half of which fail),
# so roughly 25% of SLI requests return 500: a ~25x burn rate.
hey -z 60m -c 2 -q 5 "$API/items" >/dev/null & pids+=($!)
chaos_pid=""
hey -z 60m -c 2 -q 5 "$API/chaos?rate=$CHAOS_RATE" >/dev/null & chaos_pid=$!; pids+=($chaos_pid)
start=$(date +%s)
echo "$(date -u +%T) error injection started (/chaos?rate=$CHAOS_RATE)"

wait_for_state firing
fired=$(date +%s)
report
echo "FIRING: $ALERT fired $((fired - start))s after errors started; holding for ${HOLD_SECONDS}s"
sleep "$HOLD_SECONDS"

kill "$chaos_pid"
recovered=$(date +%s)
echo "$(date -u +%T) error injection stopped; normal traffic continues"
wait_for_state inactive
cleared=$(date +%s)
report
echo "CLEARED: $ALERT resolved $((cleared - recovered))s after errors stopped"
echo "PASS: alert fired under error injection and cleared after recovery"
