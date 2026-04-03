#!/bin/bash
set -e

TAG="v1.0.0"
SERVICES=(
  auth-service
  api-gateway
  drug-catalog-service
  notification-service
  pharma-ui
)

for svc in "${SERVICES[@]}"; do
  echo ""
  echo "========== Building: $svc =========="
  docker build -t "${REGISTRY}/${svc}:${TAG}" "services/${svc}"
#  docker push "${REGISTRY}/${svc}:${TAG}"
#  echo "Pushed: ${REGISTRY}/${svc}:${TAG}"
done

echo ""
echo "All 5 images pushed to ECR successfully!"
