#!/bin/bash
set -e

kubectl run pod-setup --image=amazon/aws-cli:2.37.6 --restart=Never \
  --env="AWS_ACCESS_KEY_ID=rustfsadmin" \
  --env="AWS_SECRET_ACCESS_KEY=rustfsadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- --endpoint-url http://rustfs.rustfs.svc:9000 s3 mb s3://test-bucket

kubectl wait pod/pod-setup --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl delete pod pod-setup
