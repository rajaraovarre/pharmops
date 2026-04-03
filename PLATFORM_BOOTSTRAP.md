# PharmOps — Platform Bootstrap Guide

> **Goal:** Get all 5 microservices running on EKS via ArgoCD.
> CI/CD (GitHub Actions) comes in Phase 2. Monitoring comes in Phase 3.

---

```
Create VPC + ECR + EKS + RDS  ← all four together in Phase 1
```

This is still simple — one `terraform apply` creates everything.

---

## Phase 1 Overview

```
Step 1  → Terraform: VPC + ECR + EKS + RDS  (15–25 min, automated)
Step 2  → Connect kubectl to the new EKS cluster
Step 3  → Install ArgoCD on the cluster
Step 4  → Build Docker images locally and push to ECR
Step 5  → Push GitOps config to GitHub (pharmops-gitops repo)
Step 6  → Apply ArgoCD manifests (one Application per service)
Step 7  → ArgoCD deploys all 5 services
Step 8  → Verify everything is running
```


---

## Services in This Phase

| Service | Stack | Port | Purpose |
|---------|-------|------|---------|
| `auth-service` | Spring Boot | 8081 | Login, JWT, user management |
| `api-gateway` | Spring Boot | 8080 | Routing + JWT validation |
| `catalog-service` | Spring Boot | 8082 | CRUD demo — drugs, dosages |
| `notification-service` | Node.js | 3000 | Email notifications (different stack) |
| `pharma-ui` | React + Nginx | 80 | Frontend |

> **Why these 5?** Covers 3 tech stacks (Java, Node.js, React), a complete auth flow,
> one real business domain for CRUD demos, and fits comfortably on a single t2.small node.

---

## Step 1 — Terraform: Create All Infrastructure

### 1.1 Bootstrap Remote State (One-Time)

```bash
# Create S3 bucket for Terraform state
aws s3api create-bucket --bucket pharma-tf-state --region us-east-1
aws s3api put-bucket-versioning \
  --bucket pharma-tf-state \
  --versioning-configuration Status=Enabled

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name pharma-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 1.2 Create terraform.tfvars

```bash
cd pharma-devops/terraform/envs/dev

cat > terraform.tfvars << 'EOF'
db_password = "PharmaSecure#2024Dev!"
jwt_secret  = "pharma-jwt-super-secret-dev-key-min-32-chars"
EOF
```

### 1.3 Apply

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**What gets created:**

| Resource | Details | Why |
|----------|---------|-----|
| VPC | 10.0.0.0/16, 3 subnet tiers | Network isolation |
| EKS Cluster | pharma-dev, v1.33, t2.small | Kubernetes control plane |
| RDS PostgreSQL | db.t3.micro, pharmadb | Shared database, schema-per-service |
| ECR Repositories | 5 repos (one per service) | Private Docker registry |
| IAM Roles | ESO role, node role | Least-privilege AWS access |
| Secrets Manager | dev/pharma/db, dev/pharma/jwt | No secrets in code |

> **Teaching point:** One `terraform apply` creates ~30 AWS resources in the right order.
> This is IaC — repeatable, version-controlled, reviewable infrastructure.

---

## Step 2 — Connect kubectl

```bash
# Configure kubectl to talk to the new EKS cluster
aws eks update-kubeconfig \
  --region us-east-1 \
  --name pharma-dev \
  --alias pharma-dev

# Verify — should show 2 nodes in Ready state
kubectl get nodes

# Show node details (instance type, AZ)
kubectl get nodes -o wide
```

---

## Step 3 — Install Cluster Add-ons

All K8s and ArgoCD manifests are in the `pharmops-gitops` repo. Clone it first if you haven't already:

```bash
git clone https://github.com/ravdy/pharmops-gitops.git
cd pharmops-gitops
```

```bash
# Add Helm repos
helm repo add ingress-nginx    https://kubernetes.github.io/ingress-nginx
helm repo add external-secrets https://charts.external-secrets.io
helm repo add argo             https://argoproj.github.io/argo-helm
helm repo update

# Create namespaces
kubectl apply -f k8s/namespaces.yaml

# Install NGINX Ingress Controller
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --values k8s/ingress/nginx-values.yaml --wait

# Install External Secrets Operator
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace kube-system \
  --set installCRDs=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/pharma-dev-eso-role" \
  --wait

# Apply ExternalSecrets (ESO pulls secrets from AWS Secrets Manager into K8s)
kubectl apply -f k8s/external-secrets/cluster-secret-store.yaml
kubectl apply -f k8s/external-secrets/dev-external-secrets.yaml

# Install ArgoCD
kubectl apply -f argocd/install/argocd-namespace.yaml
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --wait
```

Verify ArgoCD is up:
```bash
kubectl get pods -n argocd
# All pods should be Running
```

Get ArgoCD password:
```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
```

---

## Step 4 — Initialize Database Schemas

The first time RDS is created, it has no schemas. Create them before deploying services:

```bash
export RDS_ENDPOINT=$(terraform output -raw rds_endpoint)

kubectl run psql-init --rm -it \
  --image=postgres:15-alpine \
  --namespace=dev \
  --env="PGPASSWORD=PharmaSecure#2024Dev!" \
  -- psql -h ${RDS_ENDPOINT} -U pharmaadmin -d pharmadb \
  -c "
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS catalog;
GRANT ALL ON SCHEMA auth, catalog TO pharmaadmin;
SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%';
"
```

---

## Step 5 — Build Docker Images and Push to ECR

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin ${REGISTRY}
```
Note: if you are getting error then please use below command 
create a file build-all.sh under pharma-devops directory. 
**Mac/Linux — build-all.sh:**
```bash
#!/bin/bash
set -e

TAG="v1.0.0"
SERVICES=(
  auth-service
  api-gateway
  catalog-service
  notification-service
  pharma-ui
)

for svc in "${SERVICES[@]}"; do
  echo ""
  echo "========== Building: $svc =========="
  docker build -t "${REGISTRY}/${svc}:${TAG}" "services/${svc}"
  docker push "${REGISTRY}/${svc}:${TAG}"
  echo "Pushed: ${REGISTRY}/${svc}:${TAG}"
done

echo ""
echo "All 5 images pushed to ECR successfully!"
```

```bash
chmod +x build-all.sh && ./build-all.sh
```

> **Teaching point while images build (15–20 min):**
> Show students the Dockerfiles. Point out multi-stage builds:
> - Stage 1: Maven builds the JAR (heavy — JDK + all dependencies)
> - Stage 2: Copies only the JAR into a slim JRE image
> - Final image: ~200MB instead of ~500MB

---

## Step 6 — Push GitOps Config to GitHub

ArgoCD watches the `pharmops-gitops` repository at `https://github.com/ravdy/pharmops-gitops.git`.
This repo contains everything that runs on the cluster — Helm charts, ArgoCD apps, K8s manifests, and DB init scripts.

### Repo structure

```
pharmops-gitops/
├── pharma-service/              # shared Helm chart (all services use this)
│   ├── Chart.yaml
│   ├── values.yaml              # defaults
│   └── templates/
├── envs/
│   ├── dev/
│   │   ├── values-pharma-ui.yaml
│   │   ├── values-api-gateway.yaml
│   │   ├── values-auth-service.yaml
│   │   ├── values-notification-service.yaml
│   │   └── values-catalog-service.yaml
│   ├── qa/
│   └── prod/
├── argocd/
│   ├── install/                 # ArgoCD namespace + ingress
│   ├── projects/                # ArgoCD AppProject
│   └── apps/dev/                # per-service Application manifests
├── k8s/
│   ├── namespaces.yaml
│   ├── rbac/
│   ├── ingress/
│   └── external-secrets/
└── db-init/                     # SQL schema init scripts
```

If you are setting this up from scratch, push the local `pharmops-gitops/` folder to GitHub:

```bash
cd pharmops-gitops
git init && git checkout -b main
git add .
git commit -m "Initial GitOps config"
git remote add origin https://github.com/ravdy/pharmops-gitops.git
git push -u origin main
```

Update image repositories and tags in the dev values files before pushing:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

for svc in auth-service api-gateway catalog-service notification-service pharma-ui; do
  FILE="envs/dev/values-${svc}.yaml"
  [ -f "$FILE" ] && sed -i "s|repository:.*|repository: ${REGISTRY}/${svc}|" "$FILE"
  [ -f "$FILE" ] && sed -i "s|tag:.*|tag: v1.0.0|" "$FILE"
done

git add . && git commit -m "Set ECR image tags v1.0.0 for dev" && git push
```

> **Two repos, clear responsibilities:**
> - `pharmops` → Terraform only (AWS infrastructure)
> - `pharmops-gitops` → everything on the cluster (Helm, ArgoCD, K8s, DB init)

---

## Step 7 — Configure and Apply ArgoCD

### 7.1 Port-Forward ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open: https://localhost:8080
# Username: admin  |  Password: (from Step 3)
```

### 7.2 Apply ArgoCD Project and Per-Service Applications

All ArgoCD and K8s manifests now live in the `pharmops-gitops` repo. Run these from inside that directory.

```bash
cd pharmops-gitops

# Apply the ArgoCD project first
kubectl apply -f argocd/projects/pharma-project.yaml

# Apply individual Application manifests for each service
kubectl apply -f argocd/apps/dev/pharma-ui/application.yaml
kubectl apply -f argocd/apps/dev/api-gateway/application.yaml
kubectl apply -f argocd/apps/dev/auth-service/application.yaml
kubectl apply -f argocd/apps/dev/notification-service/application.yaml
kubectl apply -f argocd/apps/dev/catalog-service/application.yaml

# Apply RBAC
kubectl apply -f k8s/rbac/cluster-roles.yaml
kubectl apply -f k8s/rbac/dev-role.yaml
kubectl apply -f k8s/rbac/rolebindings.yaml
```

Each Application points to the same shared chart but a different values file:

```yaml
source:
  repoURL: https://github.com/ravdy/pharmops-gitops.git
  path: pharma-service                          # shared chart
  helm:
    valueFiles:
      - ../envs/dev/values-auth-service.yaml    # service-specific overrides
```

### 7.3 Sync and Watch

In the ArgoCD UI you will see 5 separate applications — one per service:
- `pharma-ui-dev`
- `api-gateway-dev`
- `auth-service-dev`
- `notification-service-dev`
- `catalog-service-dev`

Click **Sync** on each, or sync all from terminal:

```bash
# Sync all apps at once (requires argocd CLI)
argocd app sync pharma-ui-dev api-gateway-dev auth-service-dev notification-service-dev catalog-service-dev

# Watch pods come up
kubectl get pods -n dev -w
```

---

## Step 8 — Verify

```bash
# All 5 pods should be Running
kubectl get pods -n dev

# Check services
kubectl get svc -n dev

# Test auth service
kubectl port-forward svc/auth-service -n dev 8081:8081 &

curl http://localhost:8081/actuator/health
# {"status":"UP"}

curl -X POST http://localhost:8081/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@pharma.com","password":"Admin@123"}'
# Returns JWT token

# Test catalog service
kubectl port-forward svc/catalog-service -n dev 8082:8082 &

curl http://localhost:8082/actuator/health
# {"status":"UP"}
```

---

## Phase 1 Complete

Students can now see:
- 5 microservices running on Kubernetes
- ArgoCD managing each service independently — sync, rollback, and health per service
- Secrets pulled from AWS Secrets Manager (not hardcoded)
- NGINX Ingress routing traffic
- One shared Helm chart rendering different manifests per service via values files

**Next sessions build on this:**
- Phase 2: GitHub Actions CI/CD (automate the manual docker build + push you just did)
- Phase 3: Monitoring with Prometheus + Grafana
- Concepts sessions: Use this running cluster to demonstrate every K8s concept live
