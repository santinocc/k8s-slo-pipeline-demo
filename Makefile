# Common tasks for the k8s-slo-pipeline-demo learning project.

PYTHON  ?= python3.12
VENV    := .venv
BIN     := $(VENV)/bin
IMAGE   ?= slo-demo-api
PIPELINE_IMAGE ?= slo-demo-pipeline
TAG     ?= dev
# Same pinned image as the in-cluster StatefulSet; used by test-integration.
POSTGRES_IMAGE := postgres:17.11-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b

CLUSTER     := slo-demo
NAMESPACE   := slo-demo
# Every kubectl/helm call targets the kind cluster explicitly, never the current context.
KUBECTL     := kubectl --context kind-$(CLUSTER)
HELM        := helm --kube-context kind-$(CLUSTER)
K8S_VERSION := 1.37.0
METRICS_SERVER_CHART_VERSION := 3.14.0

.DEFAULT_GOAL := help
.PHONY: help venv lint format test test-integration build image-size run \
	cluster secret deploy redeploy validate rollout-check load-test status teardown \
	ingest-now pipeline-check pipeline-fail-demo

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

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

build: ## Build the API and pipeline container images
	docker build -t $(IMAGE):$(TAG) app
	docker build -t $(PIPELINE_IMAGE):$(TAG) pipeline

image-size: ## Print the image sizes
	@for i in $(IMAGE) $(PIPELINE_IMAGE); do \
		docker image inspect $$i:$(TAG) --format '{{.Size}}' | awk -v n=$$i:$(TAG) '{printf "%s %.1f MB\n", n, $$1/1000/1000}'; \
	done

run: build ## Run the API image locally on :8000 using values from .env
	docker run --rm -p 8000:8000 --env-file .env $(IMAGE):$(TAG)

.env:
	@sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$$(openssl rand -hex 16)/" .env.example > .env
	@echo "Created .env from .env.example with a random POSTGRES_PASSWORD (git-ignored)."

cluster: ## Create the kind cluster and install metrics-server
	@kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config kind/kind-config.yaml
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
	$(KUBECTL) apply --dry-run=client -k k8s/base

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

status: ## Show pods, Jobs, CronJobs, HPA, and Services
	$(KUBECTL) -n $(NAMESPACE) get pods,jobs,cronjobs,hpa,svc -o wide

teardown: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
