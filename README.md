# Pharma DevOps — Complete Project

## Project Overview
Healthcare pharma manufacturing system with 5 microservices deployed on AWS EKS.

## Architecture
- **Frontend**: React.js (pharma-ui)
- **API Gateway**: Spring Boot (routes all traffic)
- **Backend Services**: 2 Spring Boot microservices (auth, drug-catalog)
- **Async**: Node.js (notification-service)
- **Database**: PostgreSQL on AWS RDS (schema-per-service)
- **CI/CD**: GitHub Actions + ArgoCD (GitOps)
- **Infrastructure**: Terraform on AWS EKS

## Repository Structure
```
pharma-devops/
├── services/              # All 5 microservices
│   ├── pharma-ui/         # React frontend
│   ├── api-gateway/       # Spring Boot gateway
│   ├── auth-service/      # JWT authentication
│   ├── drug-catalog-service/ # Drug CRUD demo
│   └── notification-service/ # Node.js async alerts
├── terraform/             # Infrastructure as Code
├── helm-charts/           # Kubernetes Helm charts
├── argocd/                # ArgoCD applications
├── k8s/                   # Raw K8s manifests
├── .github/workflows/     # GitHub Actions CI/CD
└── docker-compose.yml     # Local development
```

## Quick Start (Local Development)
```bash
# Start all services locally
docker-compose up -d

# Access the UI
open http://localhost:3001

# Default credentials: admin / admin123
```

## Deploy to AWS EKS
```bash
# 1. Provision infrastructure
cd terraform/envs/dev
terraform init
terraform apply

# 2. Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/apps/dev/pharma-dev-app.yaml

# 3. ArgoCD will auto-sync all services from Helm charts
```

## Services & Ports
| Service | Port | Description |
|---------|------|-------------|
| pharma-ui | 3001 | React frontend |
| api-gateway | 8080 | Entry point + JWT routing |
| auth-service | 8081 | Authentication + JWT |
| drug-catalog-service | 8082 | Drug management (CRUD demo) |
| notification-service | 3000 | Email/SMS alerts (Node.js) |
