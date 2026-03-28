#!/bin/bash
set -e

# pod-a と pod-b を同時に起動して書き込む
kubectl run pod-a --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=minioadmin" \
  --env="AWS_SECRET_ACCESS_KEY=minioadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- aws --endpoint-url http://minio.minio.svc:9000 \
  s3 cp /etc/hostname s3://test-bucket/pod-a.txt &

kubectl run pod-b --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=minioadmin" \
  --env="AWS_SECRET_ACCESS_KEY=minioadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- aws --endpoint-url http://minio.minio.svc:9000 \
  s3 cp /etc/hostname s3://test-bucket/pod-b.txt &

wait
echo "両 Pod の起動リクエスト完了"

# 結果確認
echo "--- Pod ステータス ---"
kubectl get pod pod-a pod-b

echo "--- バケット内容 ---"
kubectl run pod-check --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=minioadmin" \
  --env="AWS_SECRET_ACCESS_KEY=minioadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- aws --endpoint-url http://minio.minio.svc:9000 \
  s3 ls s3://test-bucket/

kubectl wait pod/pod-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
kubectl logs pod/pod-check
kubectl delete pod pod-check

# クリーンアップ
kubectl delete pod pod-a pod-b
