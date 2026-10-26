# Common tasks for the k8s-slo-pipeline-demo learning project.
# Cluster targets (cluster, deploy, load-test, teardown) are added in later milestones.

PYTHON  ?= python3.12
VENV    := .venv
BIN     := $(VENV)/bin
IMAGE   ?= slo-demo-api
TAG     ?= dev

.DEFAULT_GOAL := help
.PHONY: help venv lint format test build image-size run

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
