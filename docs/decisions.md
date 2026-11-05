# Architecture decision records

Short records of the main choices in this learning project, written in the
Context, Decision, Consequences format. Each one explains why the simpler or
local option was chosen, and what would change for real production use.

---

## ADR-001: Use kind for the local Kubernetes cluster

**Status:** accepted (2026-11-02)

**Context.** The project has to run on a laptop, cost nothing, and be easy for
someone else to reproduce. No cloud resources are allowed. The options were kind,
minikube, k3d, and a managed cluster such as EKS.

**Decision.** Use kind with one control-plane node. The node image is pinned by
digest in `kind/kind-config.yaml`. Services are exposed as NodePorts, and kind's
port mappings make them reachable on `localhost` (API :8080, Prometheus :9090,
Grafana :3000).

**Consequences.**
- One command (`make cluster`) creates the same cluster every time, and
  `make teardown` removes it completely.
- Locally built images are loaded with `kind load`, so no registry is needed.
- A single node does not show scheduling, node failure, or zone spread. The HPA
  demo adds pods on the same node, so throughput does not grow with replicas.
- I chose NodePorts over `kubectl port-forward` because port-forward connects to
  a single pod and breaks during rollouts. That would have made the zero-downtime
  check fail for the wrong reason.

---

## ADR-002: Write the API and pipeline in Python with FastAPI

**Status:** accepted (2026-11-02)

**Context.** The role this project supports uses Python for data and ML tooling.
The API needs only a few endpoints, Prometheus metrics, and PostgreSQL access.

**Decision.** Use Python 3.12 with FastAPI and uvicorn for the API, psycopg 3
with a connection pool for PostgreSQL, and `prometheus_client` for metrics.
The ingestion job is a plain Python script using psycopg. ruff handles lint and
format, and pytest runs the tests. All dependencies are pinned.

**Consequences.**
- FastAPI validates query parameters and provides dependency injection, so the
  database can be swapped for fakes in tests. `make test` needs no database.
- The images are about 188 MB (API) and 172 MB (pipeline). Most of that is the
  `python:3.12-slim` base image. A distroless or Alpine base would be smaller,
  but harder to debug.
- Metrics are labelled with the route template (`/items`), not the raw path, to
  keep the number of time series small.

---

## ADR-003: Alert on SLO error-budget burn rate over two windows

**Status:** accepted (2026-11-03)

**Context.** A simple alert such as "error rate > 5% for 5 minutes" is either
noisy (it fires on short blips) or slow (it misses steady low-level errors).
The SLO is 99% of requests non-5xx over 28 days, so the error budget is 1%.

**Decision.** Use the multi-window, multi-burn-rate approach from the Google SRE
Workbook:
- `SLOErrorBudgetBurnFast` (severity `page`): error ratio above 14.4x the budget
  (14.4%) over both 1h and 5m, for 2m.
- `SLOErrorBudgetBurnSlow` (severity `ticket`): error ratio above 6x the budget
  (6%) over both 6h and 30m, for 15m.

The SLO is defined once in `slo/slo.yaml`. A pytest check makes sure
`monitoring/slo-rules.yaml` implements exactly those queries and thresholds, and
promtool unit tests check when each alert fires and clears.

**Consequences.**
- The long window means the alert fires only when a meaningful part of the
  budget is at risk. The short window means it clears soon after recovery. In
  the demo the alert cleared 272 s after errors stopped, while the 1h error
  ratio was still at 20%.
- Probe and scrape routes (`/health`, `/ready`, `/metrics`) are left out of the
  SLI, so Kubernetes and Prometheus traffic cannot hide real errors.
- When there is no traffic, the error ratio has no value, and nothing fires.
  That is acceptable here; a real service would also want an alert for "no traffic".

---

## ADR-004: Run the pipeline as a Kubernetes CronJob, not Airflow

**Status:** accepted (2026-11-03)

**Context.** The pipeline is one step: generate about 50 rows and upsert them
into PostgreSQL every 5 minutes. It needs a schedule, retries, a guard against
overlapping runs, and a visible failure.

**Decision.** Use a Kubernetes CronJob with `concurrencyPolicy: Forbid`,
`backoffLimit: 3`, `restartPolicy: Never` (each retry is a new pod you can see),
`activeDeadlineSeconds: 240`, and a short history of failed Jobs. The script
upserts all rows in one statement, so re-running it is safe.

**Consequences.**
- No extra system to install or run. Everything is visible with `kubectl get
  cronjobs,jobs,pods`, and kube-state-metrics feeds the pipeline panels in Grafana.
- There is no dependency graph between tasks, no backfill UI, and no
  data-lineage view. For a multi-step pipeline with dependencies between steps,
  Airflow (or Argo Workflows, or Step Functions on AWS) would be the better
  choice.
- The upsert skips rows whose values did not change, so a re-run in the same
  5-minute window touches nothing.

---

## ADR-005: Trim kube-prometheus-stack to fit a 4 CPU / 4 GB cluster

**Status:** accepted (2026-11-03)

**Context.** The development machine is an 8 GB Apple M1 laptop, and Docker
Desktop has 4 CPUs and 4 GB of memory. With the chart's default values,
kube-prometheus-stack overloaded the node: the load average reached about 65,
kube-scheduler and kube-controller-manager restarted in a loop, and the API
server timed out.

**Decision.** Keep only what the SLO demo uses: Prometheus, Alertmanager,
Grafana, kube-state-metrics, and the operator. Turn off the default scrapes of
the API server, kubelet/cAdvisor, CoreDNS, and node-exporter, plus the default
recording rules, alerts, and dashboards. Set small resource requests and limits.
The reasons are written at the top of `monitoring/kube-prometheus-stack-values.yaml`.

**Consequences.**
- On a fresh cluster every pod is Ready with no restarts, and the node load
  stays low.
- There are no node or container resource dashboards, and no default alerts for
  cluster health. With 6 CPUs and 6 GB for Docker, those defaults can be turned
  back on.
- In production I would keep the default rules and dashboards, and run
  Prometheus with proper resources or use a managed service.
