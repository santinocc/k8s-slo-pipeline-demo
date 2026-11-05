# Runbook: SLO error-budget burn-rate alerts

For `SLOErrorBudgetBurnFast` and `SLOErrorBudgetBurnSlow` on the
`api-availability` SLO. This is a learning project. The steps work on the
local kind cluster, and the commands assume the repository root as the working
directory. The production differences are noted at the end.

| Alert | Fires when | Severity | Means | Respond |
|---|---|---|---|---|
| `SLOErrorBudgetBurnFast` | error ratio > 14.4% over **1h and 5m**, for 2m | `page` | The 28-day budget would be gone in about 2 days | Now |
| `SLOErrorBudgetBurnSlow` | error ratio > 6% over **6h and 30m**, for 15m | `ticket` | The budget would be gone in under 5 days | Same working day |

An "error" is a 5xx response from `/items` or any other route except
`/health`, `/ready`, and `/metrics` (see [`slo/slo.yaml`](../slo/slo.yaml)).

Shortcuts used below:

```bash
K="kubectl --context kind-slo-demo -n slo-demo"
```

```bash
promq() { curl -sG localhost:9090/api/v1/query --data-urlencode "query=$1"; echo; }
```

## 1. Confirm (2 minutes)

1. Open the dashboard: <http://localhost:3000/d/slo-demo-api>. Check the
   "Error ratio vs burn-rate thresholds" panel. Is the 5m line still above
   the threshold, or already falling?
2. Check the alert and the current error ratios:

   ```bash
   promq 'ALERTS{alertname=~"SLOErrorBudgetBurn.*"}'
   ```

   ```bash
   promq 'slo:sli_error:ratio_rate5m'
   ```

   A value of `NaN` means there was no traffic in the window (0 / 0), not zero errors.
3. Check the remaining budget. `1` is untouched; `0` or below is exhausted.

   ```bash
   promq 'slo:error_budget_remaining:ratio'
   ```

If the 5m ratio is already back under the threshold, the alert clears within a
few minutes (in the demo it cleared 272 s after errors stopped). Still do step
2 to find out why it happened.

## 2. Find the scope (5 minutes)

Which routes, status codes, and pods are failing? An empty result means no 5xx.

```bash
promq 'sum by (route, status) (rate(http_requests_total{job="api", namespace="slo-demo", status=~"5.."}[5m]))'
```

```bash
promq 'sum by (pod) (rate(http_requests_total{job="api", namespace="slo-demo", status=~"5.."}[5m])) / sum by (pod) (rate(http_requests_total{job="api", namespace="slo-demo"}[5m]))'
```

Then look at the cluster:

```bash
$K get pods,hpa -o wide
```

```bash
$K get events --sort-by=.lastTimestamp | tail -20
```

The API runs without access logs (the metrics already count every request),
so its logs show only startup messages, warnings, and tracebacks, such as
database connection errors. This reads all API pods, with the pod name on each
line:

```bash
$K logs -l app.kubernetes.io/name=api --since=10m --prefix --tail=50
```

`--previous` shows the logs of a container that restarted.

```bash
$K rollout history deployment/api
```

```bash
$K get deployment api -o jsonpath='{.spec.template.spec.containers[0].env}'; echo
```

Use what you found to pick a row in step 3:

| What you see | Likely cause |
|---|---|
| Errors on `/chaos` or `CHAOS_ENABLED=true` in the env | Error injection left on |
| Errors started right after a rollout (new revision, new pods) | Bad change |
| `/items` returns 503, and `/ready` fails on every pod | PostgreSQL is down or unreachable |
| Errors on every pod, high CPU, HPA at 6, restarts | Overload |
| Errors on one pod only | One bad pod |

## 3. Mitigate (stop the bleeding first)

Fix the user impact first; find the root cause after.

**Error injection left on.** Remove the variable; this rolls the pods.

```bash
$K set env deployment/api CHAOS_ENABLED-
```

```bash
$K rollout status deployment/api --timeout=180s
```

**Bad change: roll back.** Return to the previous revision:

```bash
$K rollout undo deployment/api
```

```bash
$K rollout status deployment/api --timeout=180s
```

To go back further, pick a revision from `rollout history` and add `--to-revision=N`.

`rollout undo` is the fast fix, but git is still the source of truth. kubectl
warns that the undo does not update the `last-applied-configuration`
annotation. Afterwards, revert the bad change in git and run
`kubectl apply -k k8s/base`, so the next deploy does not bring it back.

Drill on 2026-11-05: `CHAOS_ENABLED=true` was set as a stand-in bad change,
then `rollout undo` restored the previous revision in 16 s. A curl loop sent
200 requests to `/items` during the undo: 0 failed. `/chaos` went from 200
back to 404.

`rollout undo` restores the previous **pod template**: environment variables,
probes, resources, and the image reference. In this project every build is
tagged `slo-demo-api:dev`, so it cannot bring back older code. To roll back
code, check out the previous commit and run `make redeploy`. With immutable
image tags, `rollout undo` would cover code too.

**PostgreSQL down.**

```bash
$K get pod postgres-0
```

```bash
$K logs postgres-0 --tail=50
```

```bash
$K exec postgres-0 -- pg_isready -U "$($K get secret postgres-credentials -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
```

If the pod is stuck, delete it. The StatefulSet recreates it, and the data
stays on the volume:

```bash
$K delete pod postgres-0
```

```bash
$K rollout status statefulset/postgres --timeout=180s
```

**Overload.** Stop the source of the load if it is a test. Otherwise add
capacity. On this single node, more pods do not help once the CPU is full, so
remove other load first.

```bash
$K patch hpa api -p '{"spec":{"maxReplicas":8}}'
```

**One bad pod.** Delete it; the Deployment replaces it.

```bash
$K delete pod <pod-name>
```

## 4. Verify recovery

1. The 5m error ratio is under the threshold and falling, and the 1h ratio
   follows over the next hour.

   ```bash
   promq 'slo:sli_error:ratio_rate5m'
   ```

2. The alert leaves the firing state at <http://localhost:9090/alerts>.
3. Run the rollout check if you changed the Deployment:

   ```bash
   make rollout-check
   ```

## 5. Follow up

- Write down the timeline: when errors started, when the alert fired, what you
  changed, and when it cleared. [slo-alert-demo.md](slo-alert-demo.md) is an
  example.
- Note how much error budget the incident used, from the "Error budget
  remaining" panel.
- If the budget is close to 0, pause risky changes until it recovers. That is
  the usual error-budget policy.
- Fix the root cause, and add a test or alert that would have caught it earlier.

## Blind spots

- The SLI counts only responses the API sent. Timeouts and requests to a
  restarting pod are not counted. During an overload the dashboard can show
  100% while users see errors (see
  [the walkthrough](walkthrough.md#5-grafana-dashboard-overloaded)). If users
  report problems and the SLO looks fine, check pod restarts and latency.
- With no traffic, the error ratio is `NaN` and nothing fires. There is no
  "no traffic" alert.
- On a single node, a node problem takes everything down, including Prometheus,
  so the alert itself may not fire.

## Practice

`make slo-alert-demo` turns on error injection, waits for the fast alert to
fire, then turns it off and waits for it to clear. Use it to practice steps 1–4.

## In production

- Alertmanager would route `page` alerts to the on-call tool and `ticket`
  alerts to a team queue. The alerts link here through their `runbook_url`
  annotation.
- Images would use immutable tags (a version or git SHA), so `rollout undo`
  rolls back code as well as config. A canary rollout (Argo Rollouts) gated on
  this SLO could roll back automatically.
- The database would be managed (RDS or Aurora), and its failover runbook
  would replace the PostgreSQL steps above.
