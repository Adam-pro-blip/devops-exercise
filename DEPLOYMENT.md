# YellowPad Kubernetes Deployment Guide

This guide is for IT teams deploying the YellowPad on-premises exercise stack into a local Kubernetes cluster. It uses `kind` and Kustomize-compatible manifests under `k8s/`.

## Prerequisites

- macOS, Linux, or Windows with WSL2 and at least 4 CPU cores, 8 GB RAM, and 10 GB free disk.
- Docker Engine or Docker Desktop.
- `kubectl` 1.29+.
- `kind` 0.23+.
- Access to build the local YellowPad container images from this repository.
- Optional: `curl` for command-line verification.

## Quick Start

The fastest path is:

```bash
make up
make verify
```

The equivalent manual steps are:

1. Create the local cluster:

   ```bash
   kind create cluster --config k8s/kind-cluster.yaml
   ```

2. Build the three application images:

   ```bash
   docker build -t localhost/yellowpad/api-gateway:local src/api-gateway
   docker build -t localhost/yellowpad/document-processor:local src/document-processor
   docker build -t localhost/yellowpad/web-ui:local src/web-ui
   ```

3. Load the images into the kind cluster:

   ```bash
   kind load docker-image localhost/yellowpad/api-gateway:local --name yellowpad
   kind load docker-image localhost/yellowpad/document-processor:local --name yellowpad
   kind load docker-image localhost/yellowpad/web-ui:local --name yellowpad
   ```

4. For a real client deployment, replace the sample credentials in `k8s/secrets.yaml` before applying the stack. To generate replacement Secret YAML without storing secrets in shell history, first create only the namespace, then run a command like this and copy the generated values into your private deployment overlay or secret-management workflow:

   ```bash
   kubectl apply -f k8s/namespace.yaml

   kubectl create secret generic yellowpad-db \
     --namespace yellowpad \
     --from-literal=POSTGRES_USER=yellowpad \
     --from-literal=POSTGRES_PASSWORD='<change-me>' \
     --from-literal=DB_USER=yellowpad \
     --from-literal=DB_PASSWORD='<change-me>' \
     --dry-run=client -o yaml
   ```

   The included `k8s/secrets.yaml` is suitable for local exercise use only.

5. Deploy the stack:

   ```bash
   kubectl apply -k k8s
   ```

6. Wait for the pods:

   ```bash
   kubectl rollout status -n yellowpad deploy/redis
   kubectl rollout status -n yellowpad deploy/api-gateway
   kubectl rollout status -n yellowpad deploy/document-processor
   kubectl rollout status -n yellowpad deploy/web-ui
   kubectl rollout status -n yellowpad statefulset/postgres
   kubectl rollout status -n yellowpad statefulset/minio
   ```

7. Open the web UI from the host:

   ```bash
   open http://localhost:30080
   ```

   If your platform does not support `open`, browse to `http://localhost:30080`.

## Verification

Check all pods are ready:

```bash
kubectl get pods -n yellowpad
```

Or use the bundled verification target:

```bash
make verify
```

Check the API health endpoint:

```bash
kubectl port-forward -n yellowpad svc/api-gateway 8000:8000
curl http://localhost:8000/healthz
```

Expected response:

```json
{"api":"ok","database":"ok","redis":"ok","minio":"ok"}
```

Upload a document:

```bash
curl -X POST http://localhost:8000/documents \
  -H "Content-Type: application/json" \
  -d '{"filename":"test.pdf","content":"hello world"}'
```

Process the document:

```bash
kubectl port-forward -n yellowpad svc/document-processor 8001:8001
curl -X POST http://localhost:8001/process/1
```

## Architecture Overview

```text
Host browser
  |
  | http://localhost:30080
  v
web-ui NodePort Service -> web-ui Deployment (Nginx)
  |
  | /api/* proxy
  v
api-gateway Service -> api-gateway Deployment
  |                 |                 |
  v                 v                 v
PostgreSQL      Redis             MinIO
pgvector PVC    cache             object storage PVC

document-processor Service -> document-processor Deployment
  |                 |                 |
  v                 v                 v
PostgreSQL      Redis             MinIO
```

YellowPad runs in the dedicated `yellowpad` namespace. Application configuration is stored in `yellowpad-config`; database and object storage credentials are provided through Kubernetes Secrets. PostgreSQL and MinIO use PVCs so local data survives pod restarts.

## Common Issues

### Pods show `ImagePullBackOff`

The local images were not loaded into kind, or the tags do not match the manifests. Rebuild and reload:

```bash
docker build -t localhost/yellowpad/api-gateway:local src/api-gateway
kind load docker-image localhost/yellowpad/api-gateway:local --name yellowpad
kubectl rollout restart -n yellowpad deploy/api-gateway
```

Repeat for `document-processor` or `web-ui` if needed.

### API health returns 503

The API health check verifies PostgreSQL, Redis, and MinIO. Inspect the backing services first:

```bash
kubectl get pods -n yellowpad
kubectl logs -n yellowpad statefulset/postgres
kubectl logs -n yellowpad deploy/redis
kubectl logs -n yellowpad statefulset/minio
```

Common causes are slow first startup, PVC provisioning problems, or changed secrets that do not match the database volume initialized with older credentials.

### `localhost:30080` does not load

Confirm the cluster was created with `k8s/kind-cluster.yaml`, which maps the web UI NodePort to host port 30080. If not, recreate the cluster or use port-forwarding:

```bash
kubectl port-forward -n yellowpad svc/web-ui 30080:80
```

## Cleanup

```bash
kind delete cluster --name yellowpad
```
