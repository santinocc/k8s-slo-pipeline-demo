# Common tasks for the k8s-slo-pipeline-demo learning project.

PYTHON  ?= python3.12
VENV    := .venv
BIN     := $(VENV)/bin
IMAGE   ?= slo-demo-api
PIPELINE_IMAGE ?= slo-demo-pipeline
TAG     ?= dev
# Same pinned image as the in-cluster StatefulSet; used by test-integration.
# Same Prometheus version as kube-prometheus-stack ships; used for promtool.
PROMETHEUS_IMAGE := quay.io/prometheus/prometheus:v3.15.1-distroless@sha256:451a845bae1d51622b41af1780eb2ad911bbb79a9855bc8e9bb67fabbc03f934
POSTGRES_IMAGE := postgres:17.11-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b

CLUSTER     := slo-demo
NAMESPACE   := slo-demo
# Every kubectl/helm call targets the kind cluster explicitly, never the current context.
KUBECTL     := kubectl --context kind-$(CLUSTER)
HELM        := helm --kube-context kind-$(CLUSTER)
K8S_VERSION := 1.37.0
METRICS_SERVER_CHART_VERSION := 3.14.0
KPS_CHART_VERSION := 92.17.1
# Schemas for CRDs (ServiceMonitor, PrometheusRule) used by kubeconform.
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.DEFAULT_GOAL := help
.PHONY: help venv lint format test test-integration test-rules build image-size run \
	cluster secret deploy redeploy validate rollout-check load-test status teardown \
	ingest-now pipeline-check pipeline-fail-demo monitoring monitoring-manifests slo-alert-demo \
	tf-init tf-plan tf-apply tf-destroy tf-check

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

$(BIN)/activate: app/requirements.txt app/requirements-dev.txt
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install --quiet --upgrade pip
	$(BIN)/pip install --quiet -r app/requirements-dev.txt
	touch $@

venv: $(BIN)/activate ## Create the local virtualenv with pinned dev dependencies

lint: venv ## Run ruff lint and format checks
	$(BIN)/ruff check .
	$(BIN)/ruff format --check .

format: venv ## Auto-format and fix lint issues
	$(BIN)/ruff format .
	$(BIN)/ruff check --fix .

test: venv ## Run lint and the pytest suite
	$(MAKE) lint
	$(BIN)/pytest -q

test-integration: venv ## Run Postgres-backed tests against a throwaway container
	@cid=$$(docker run -d --rm -e POSTGRES_USER=test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test \
		-p 127.0.0.1::5432 $(POSTGRES_IMAGE)); \
	trap 'docker stop '$$cid' >/dev/null' EXIT; \
	port=$$(docker port $$cid 5432 | head -1 | cut -d: -f2); \
	for i in $$(seq 30); do docker exec $$cid pg_isready -h 127.0.0.1 -U test -d test >/dev/null 2>&1 && break; sleep 1; done; \
	TEST_POSTGRES_DSN="postgresql://test:test@127.0.0.1:$$port/test" $(BIN)/pytest -q -m integration

test-rules: venv ## Check and unit-test the SLO Prometheus rules with promtool
	@# mktemp -d is mode 700; the distroless promtool image runs as nobody and must read it.
	@dir=$$(mktemp -d); trap 'rm -rf '$$dir EXIT; chmod 755 $$dir; \
	$(BIN)/python -c 'import sys, yaml; d = yaml.safe_load(open("monitoring/slo-rules.yaml")); yaml.safe_dump(d["spec"], open(sys.argv[1], "w"), sort_keys=False)' $$dir/slo-rules.rules.yaml; \
	cp monitoring/tests/slo-rules.test.yaml $$dir/; \
	docker run --rm -v $$dir:/rules:ro -w /rules --entrypoint /bin/promtool $(PROMETHEUS_IMAGE) check rules slo-rules.rules.yaml && \
	docker run --rm -v $$dir:/rules:ro -w /rules --entrypoint /bin/promtool $(PROMETHEUS_IMAGE) test rules slo-rules.test.yaml

build: ## Build the API and pipeline container images
	docker build -t $(IMAGE):$(TAG) app
	docker build -t $(PIPELINE_IMAGE):$(TAG) pipeline

image-size: ## Check both images are under 200 MB and run as UID 10001
	scripts/image-check.sh $(IMAGE):$(TAG) $(PIPELINE_IMAGE):$(TAG)

run: build ## Run the API image locally on :8000 using values from .env
	docker run --rm -p 8000:8000 --env-file .env $(IMAGE):$(TAG)

.env:
	@sed -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$$(openssl rand -hex 16)/" \
		-e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$$(openssl rand -hex 16)/" .env.example > .env
	@echo "Created .env from .env.example with random passwords (git-ignored)."

cluster: ## Create the kind cluster and install metrics-server
	@if kind get clusters | grep -qx $(CLUSTER); then \
		kind export kubeconfig --name $(CLUSTER); \
	else kind create cluster --config kind/kind-config.yaml; fi
	$(HELM) upgrade --install metrics-server metrics-server \
		--repo https://kubernetes-sigs.github.io/metrics-server/ \
		--version $(METRICS_SERVER_CHART_VERSION) \
		--namespace kube-system -f monitoring/metrics-server-values.yaml --wait

# Postgres reads the password only when its volume is first initialised;
# changing .env later does not change the database password.
secret: .env ## Create the postgres-credentials Secret from .env
	@set -a; . ./.env; set +a; \
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f - >/dev/null; \
	$(KUBECTL) -n $(NAMESPACE) create secret generic postgres-credentials \
		--from-literal=POSTGRES_USER="$$POSTGRES_USER" \
		--from-literal=POSTGRES_PASSWORD="$$POSTGRES_PASSWORD" \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

deploy: build secret ## Build and load the images, then apply the manifests
	kind load docker-image $(IMAGE):$(TAG) $(PIPELINE_IMAGE):$(TAG) --name $(CLUSTER)
	$(KUBECTL) apply -k k8s/base
	$(KUBECTL) -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/api --timeout=180s

redeploy: build ## Rebuild the images and roll out the API (the CronJob picks up the new image on its next run)
	kind load docker-image $(IMAGE):$(TAG) $(PIPELINE_IMAGE):$(TAG) --name $(CLUSTER)
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/api
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/api --timeout=180s

validate: ## Validate manifests with kubeconform and a client-side dry run
	$(KUBECTL) kustomize k8s/base | kubeconform -strict -summary -kubernetes-version $(K8S_VERSION) -
	kubeconform -strict -summary -kubernetes-version $(K8S_VERSION) k8s/base/postgres-secret.example.yaml
	$(KUBECTL) kustomize monitoring | kubeconform -strict -summary -kubernetes-version $(K8S_VERSION) \
		-schema-location default -schema-location '$(CRD_SCHEMAS)' -
	$(KUBECTL) apply --dry-run=client -k k8s/base
	@# The monitoring dry run needs the CRDs that `make monitoring` installs.
	@if $(KUBECTL) get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then \
		$(KUBECTL) apply --dry-run=client -k monitoring; \
	else echo "Skipping monitoring dry run: run 'make monitoring' first to install the CRDs."; fi

rollout-check: ## Restart the API under a curl loop and fail on any non-200
	KUBECTL="$(KUBECTL)" NAMESPACE=$(NAMESPACE) scripts/rollout-check.sh

load-test: ## Load the API with hey and check the HPA scales up and back down
	KUBECTL="$(KUBECTL)" NAMESPACE=$(NAMESPACE) scripts/hpa-check.sh

ingest-now: ## Run the ingestion CronJob once, right now
	@job=ingest-manual-$$(date +%s); \
	$(KUBECTL) -n $(NAMESPACE) create job $$job --from=cronjob/ingest; \
	$(KUBECTL) -n $(NAMESPACE) wait --for=condition=complete job/$$job --timeout=120s; \
	$(KUBECTL) -n $(NAMESPACE) logs job/$$job

pipeline-check: ## Run ingestion twice and check the re-run is idempotent
	KUBECTL="$(KUBECTL)" NAMESPACE=$(NAMESPACE) scripts/pipeline-check.sh

pipeline-fail-demo: ## Run ingestion with a wrong DB password and watch backoffLimit retries
	KUBECTL="$(KUBECTL)" NAMESPACE=$(NAMESPACE) scripts/pipeline-fail-demo.sh

monitoring: .env ## Install kube-prometheus-stack, the ServiceMonitor, SLO rules, and dashboard
	@# Older .env files predate GRAFANA_ADMIN_PASSWORD; add a random one if missing.
	@if ! grep -q '^GRAFANA_ADMIN_PASSWORD=' .env || grep -q '^GRAFANA_ADMIN_PASSWORD=change-me$$' .env; then \
		sed -i.bak '/^GRAFANA_ADMIN_PASSWORD=/d' .env && rm -f .env.bak; \
		echo "GRAFANA_ADMIN_PASSWORD=$$(openssl rand -hex 16)" >> .env; \
		echo "Added a random GRAFANA_ADMIN_PASSWORD to .env"; \
	fi
	@set -a; . ./.env; set +a; \
	$(KUBECTL) create namespace monitoring --dry-run=client -o yaml | $(KUBECTL) apply -f - >/dev/null; \
	$(KUBECTL) -n monitoring create secret generic grafana-admin \
		--from-literal=admin-user=admin \
		--from-literal=admin-password="$$GRAFANA_ADMIN_PASSWORD" \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(HELM) upgrade --install kps kube-prometheus-stack \
		--repo https://prometheus-community.github.io/helm-charts \
		--version $(KPS_CHART_VERSION) \
		--namespace monitoring -f monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
	$(MAKE) monitoring-manifests

monitoring-manifests: ## Apply the ServiceMonitor, SLO rules, and Grafana dashboard
	$(KUBECTL) apply -k monitoring
	@echo "Grafana: http://localhost:3000/d/slo-demo-api   Prometheus: http://localhost:9090"

slo-alert-demo: ## Inject errors via /chaos until the burn-rate alert fires, then recover
	KUBECTL="$(KUBECTL)" NAMESPACE=$(NAMESPACE) scripts/slo-alert-demo.sh

status: ## Show pods, Jobs, CronJobs, HPA, and Services
	$(KUBECTL) -n $(NAMESPACE) get pods,jobs,cronjobs,hpa,svc -o wide

teardown: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

# Terraform path: creates the same kind cluster and Helm releases as
# `make cluster` plus `make monitoring`. Use one path or the other, not both.
TERRAFORM := terraform -chdir=terraform

tf-init: ## Terraform: download the pinned providers
	$(TERRAFORM) init -input=false

tf-plan: tf-init ## Terraform: plan the kind cluster and Helm releases into terraform/tfplan
	$(TERRAFORM) plan -input=false -out=tfplan

tf-apply: ## Terraform: apply the saved plan from tf-plan
	$(TERRAFORM) apply -input=false tfplan
	rm -f terraform/tfplan

tf-destroy: tf-init ## Terraform: destroy the cluster and everything in it
	$(TERRAFORM) destroy -input=false

tf-check: ## Terraform: format check and validate (no cluster needed)
	terraform -chdir=terraform fmt -check -recursive
	$(TERRAFORM) init -input=false -backend=false >/dev/null
	$(TERRAFORM) validate
