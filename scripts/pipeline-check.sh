#!/usr/bin/env bash
# Runs the ingestion CronJob twice back to back and checks that the re-run is
# idempotent: same row count, no duplicate ids, and nothing inserted twice.
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-slo-demo}"
EXPECTED_ROWS="${EXPECTED_ROWS:-50}"
k() { $KUBECTL -n "$NAMESPACE" "$@"; }

run_job() {
  local job="ingest-check-$1-$(date +%s)"
  k create job "$job" --from=cronjob/ingest >/dev/null
  k wait --for=condition=complete "job/$job" --timeout=120s >/dev/null
  k logs "job/$job" | tail -1
}

db_counts() {
  k exec postgres-0 -- sh -c \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*), count(DISTINCT id) FROM items"'
}

first=$(run_job 1)
echo "run 1: $first"
counts_1=$(db_counts)
second=$(run_job 2)
echo "run 2: $second"
counts_2=$(db_counts)
echo "rows|distinct ids after run 1: $counts_1, after run 2: $counts_2"

window() { sed -E 's/.*window=([^ ]+).*/\1/' <<<"$1"; }
fail() { echo "FAIL: $*"; exit 1; }

[[ "$counts_1" == "$EXPECTED_ROWS|$EXPECTED_ROWS" ]] || fail "expected $EXPECTED_ROWS unique rows after run 1"
[[ "$counts_2" == "$counts_1" ]] || fail "row count changed on re-run"
grep -q ' inserted=0 ' <<<"$second" || fail "re-run inserted rows"
if [[ "$(window "$first")" == "$(window "$second")" ]]; then
  grep -q ' updated=0 unchanged=50 ' <<<"$second" || fail "re-run in the same window changed rows"
else
  echo "note: runs fell in different windows, so updated values are expected"
fi

api_rows=$(curl -sf 'http://localhost:8080/items?limit=1000' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
echo "API /items returns $api_rows rows"
[[ "$api_rows" == "$EXPECTED_ROWS" ]] || fail "API returned $api_rows rows"
echo "PASS: re-run is idempotent ($EXPECTED_ROWS rows, no duplicates)"
