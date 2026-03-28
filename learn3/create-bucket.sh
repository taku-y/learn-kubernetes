#!/bin/bash
set -e

kubectl run pod-setup --image=amazon/aws-cli --restart=Never --rm \
  --env="AWS_ACCESS_KEY_ID=minioadmin" \
  --env="AWS_SECRET_ACCESS_KEY=minioadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- aws --endpoint-url http://minio.minio.svc:9000 s3 mb s3://test-bucket
