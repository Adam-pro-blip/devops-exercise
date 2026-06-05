SHELL := /bin/sh

CLUSTER_NAME ?= yellowpad
NAMESPACE ?= yellowpad
IMAGE_TOOL ?= docker
IMAGE_PREFIX ?= localhost/yellowpad
IMAGE_ARCHIVE_DIR ?= /tmp/yellowpad-images
KIND ?= kind
KUBECTL ?= kubectl

API_IMAGE := $(IMAGE_PREFIX)/api-gateway:local
PROCESSOR_IMAGE := $(IMAGE_PREFIX)/document-processor:local
WEB_IMAGE := $(IMAGE_PREFIX)/web-ui:local

.PHONY: help up cluster-create build load deploy wait status verify port-forward-web clean

help:
	@printf '%s\n' \
		'Targets:' \
		'  make up               Create kind cluster, build/load images, deploy, and wait' \
		'  make cluster-create   Create the local kind cluster' \
		'  make build            Build local application images' \
		'  make load             Load local images into kind' \
		'  make deploy           Apply Kubernetes manifests' \
		'  make wait             Wait for workloads to become ready' \
		'  make verify           Run API health, upload, processing, and status checks' \
		'  make status           Show pods, services, and PVCs' \
		'  make port-forward-web Forward web-ui to localhost:30080' \
		'  make clean            Delete the local kind cluster'

up: cluster-create build load deploy wait

cluster-create:
	@if $(KIND) get clusters | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		$(KIND) create cluster --config k8s/kind-cluster.yaml; \
	fi

build:
	$(IMAGE_TOOL) build -t $(API_IMAGE) src/api-gateway
	$(IMAGE_TOOL) build -t $(PROCESSOR_IMAGE) src/document-processor
	$(IMAGE_TOOL) build -t $(WEB_IMAGE) src/web-ui

load:
	@if [ "$(IMAGE_TOOL)" = "podman" ]; then \
		mkdir -p "$(IMAGE_ARCHIVE_DIR)"; \
		$(IMAGE_TOOL) save --format docker-archive -o "$(IMAGE_ARCHIVE_DIR)/api-gateway.tar" $(API_IMAGE); \
		$(IMAGE_TOOL) save --format docker-archive -o "$(IMAGE_ARCHIVE_DIR)/document-processor.tar" $(PROCESSOR_IMAGE); \
		$(IMAGE_TOOL) save --format docker-archive -o "$(IMAGE_ARCHIVE_DIR)/web-ui.tar" $(WEB_IMAGE); \
		$(KIND) load image-archive "$(IMAGE_ARCHIVE_DIR)/api-gateway.tar" --name $(CLUSTER_NAME); \
		$(KIND) load image-archive "$(IMAGE_ARCHIVE_DIR)/document-processor.tar" --name $(CLUSTER_NAME); \
		$(KIND) load image-archive "$(IMAGE_ARCHIVE_DIR)/web-ui.tar" --name $(CLUSTER_NAME); \
	else \
		$(KIND) load docker-image $(API_IMAGE) --name $(CLUSTER_NAME); \
		$(KIND) load docker-image $(PROCESSOR_IMAGE) --name $(CLUSTER_NAME); \
		$(KIND) load docker-image $(WEB_IMAGE) --name $(CLUSTER_NAME); \
	fi

deploy:
	$(KUBECTL) apply -k k8s

wait:
	$(KUBECTL) rollout status -n $(NAMESPACE) deploy/redis --timeout=180s
	$(KUBECTL) rollout status -n $(NAMESPACE) deploy/api-gateway --timeout=180s
	$(KUBECTL) rollout status -n $(NAMESPACE) deploy/document-processor --timeout=180s
	$(KUBECTL) rollout status -n $(NAMESPACE) deploy/web-ui --timeout=180s
	$(KUBECTL) rollout status -n $(NAMESPACE) statefulset/postgres --timeout=180s
	$(KUBECTL) rollout status -n $(NAMESPACE) statefulset/minio --timeout=180s

status:
	$(KUBECTL) get pods,svc,pvc -n $(NAMESPACE) -o wide

verify:
	@set -e; \
	$(KUBECTL) port-forward -n $(NAMESPACE) svc/api-gateway 8000:8000 >/tmp/yellowpad-api-gateway-port-forward.log 2>&1 & \
	api_pf=$$!; \
	$(KUBECTL) port-forward -n $(NAMESPACE) svc/document-processor 8001:8001 >/tmp/yellowpad-document-processor-port-forward.log 2>&1 & \
	processor_pf=$$!; \
	cleanup() { kill $$api_pf $$processor_pf >/dev/null 2>&1 || true; }; \
	trap cleanup EXIT INT TERM; \
	sleep 3; \
	printf 'API health: '; \
	curl -fsS http://localhost:8000/healthz; \
	printf '\nUpload: '; \
	upload=$$(curl -fsS -X POST http://localhost:8000/documents -H 'Content-Type: application/json' -d '{"filename":"test.pdf","content":"hello world"}'); \
	printf '%s\n' "$$upload"; \
	doc_id=$$(printf '%s' "$$upload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'); \
	printf 'Process: '; \
	curl -fsS -X POST "http://localhost:8001/process/$$doc_id"; \
	printf '\nStatus: '; \
	curl -fsS "http://localhost:8000/documents/$$doc_id"; \
	printf '\n'

port-forward-web:
	$(KUBECTL) port-forward -n $(NAMESPACE) svc/web-ui 30080:80

clean:
	$(KIND) delete cluster --name $(CLUSTER_NAME)
