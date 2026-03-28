#!/bin/bash
set -e

kubectl run pod-setup --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=minioadmin" \
  --env="AWS_SECRET_ACCESS_KEY=minioadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- --endpoint-url http://minio.minio.svc:9000 s3 mb s3://test-bucket

kubectl wait pod/pod-setup --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
kubectl delete pod pod-setup
