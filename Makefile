# Common tasks for the k8s-slo-pipeline-demo learning project.

PYTHON  ?= python3.12
VENV    := .venv
BIN     := $(VENV)/bin
IMAGE   ?= slo-demo-api
TAG     ?= dev

CLUSTER     := slo-demo
NAMESPACE   := slo-demo
# Every kubectl/helm call targets the kind cluster explicitly, never the current context.
KUBECTL     := kubectl --context kind-$(CLUSTER)
HELM        := helm --kube-context kind-$(CLUSTER)
K8S_VERSION := 1.37.0
METRICS_SERVER_CHART_VERSION := 3.14.0

.DEFAULT_GOAL := help
.PHONY: help venv lint format test build image-size run \
	cluster secret deploy redeploy validate rollout-check load-test status teardown

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

build: ## Build the API container image
	docker build -t $(IMAGE):$(TAG) app

image-size: ## Print the API image size
	@docker image inspect $(IMAGE):$(TAG) --format '{{.Size}}' | awk '{printf "$(IMAGE):$(TAG) %.1f MB\n", $$1/1000/1000}'

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

deploy: build secret ## Build and load the image, then apply the manifests
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)
	$(KUBECTL) apply -k k8s/base
	$(KUBECTL) -n $(NAMESPACE) rollout status statefulset/postgres --timeout=180s
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/api --timeout=180s

redeploy: build ## Rebuild the image and roll it out to the running Deployment
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)
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

status: ## Show pods, HPA, and Services
	$(KUBECTL) -n $(NAMESPACE) get pods,hpa,svc -o wide

teardown: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
