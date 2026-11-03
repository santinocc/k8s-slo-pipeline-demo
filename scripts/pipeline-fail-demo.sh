#!/usr/bin/env bash
# Forces a pipeline failure: runs the ingestion CronJob's Job template with a
# wrong database password, waits for the Job to fail, and checks it retried
# exactly backoffLimit times. The real Secret is not touched.
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-slo-demo}"
k() { $KUBECTL -n "$NAMESPACE" "$@"; }
job="ingest-fail-demo-$(date +%s)"

# Copy the CronJob's Job template and override only POSTGRES_PASSWORD.
k create job "$job" --from=cronjob/ingest --dry-run=client -o yaml \
  | $KUBECTL set env --local -f - POSTGRES_PASSWORD=wrong-password -o yaml \
  | k apply -f -

backoff_limit=$(k get job "$job" -o jsonpath='{.spec.backoffLimit}')
echo "Waiting for $job to fail (backoffLimit=$backoff_limit, backoff 10s/20s/40s)..."
k wait --for=condition=failed "job/$job" --timeout=240s >/dev/null

echo
k get jobs
echo
k get pods -l "job-name=$job"
echo
echo "Log from one failed attempt:"
k logs "$(k get pods -l "job-name=$job" -o name | head -1)" | tail -1
reason=$(k get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}')
failed=$(k get job "$job" -o jsonpath='{.status.failed}')
echo
echo "Job condition: Failed ($reason), failed pods: $failed"

if [[ "$reason" == "BackoffLimitExceeded" && "$failed" -eq $((backoff_limit + 1)) ]]; then
  echo "PASS: failed Job visible after 1 attempt + $backoff_limit retries"
else
  echo "FAIL: expected BackoffLimitExceeded after $((backoff_limit + 1)) attempts"
  exit 1
fi
