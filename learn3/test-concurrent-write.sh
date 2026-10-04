#!/bin/bash
set -e

# pod-a と pod-b を同時に起動して書き込む
kubectl run pod-a --image=amazon/aws-cli:2.37.6 --restart=Never \
  --env="AWS_ACCESS_KEY_ID=rustfsadmin" \
  --env="AWS_SECRET_ACCESS_KEY=rustfsadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- --endpoint-url http://rustfs.rustfs.svc:9000 \
  s3 cp /etc/hostname s3://test-bucket/pod-a.txt &

kubectl run pod-b --image=amazon/aws-cli:2.37.6 --restart=Never \
  --env="AWS_ACCESS_KEY_ID=rustfsadmin" \
  --env="AWS_SECRET_ACCESS_KEY=rustfsadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- --endpoint-url http://rustfs.rustfs.svc:9000 \
  s3 cp /etc/hostname s3://test-bucket/pod-b.txt &

wait
echo "両 Pod の起動リクエスト完了"

# kubectl run は Pod を作った時点で戻るので、書き込みの完了はここで待つ
kubectl wait pod/pod-a pod/pod-b --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s

# 結果確認
echo "--- Pod ステータス ---"
kubectl get pod pod-a pod-b

echo "--- バケット内容 ---"
kubectl run pod-check --image=amazon/aws-cli:2.37.6 --restart=Never \
  --env="AWS_ACCESS_KEY_ID=rustfsadmin" \
  --env="AWS_SECRET_ACCESS_KEY=rustfsadmin" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- --endpoint-url http://rustfs.rustfs.svc:9000 \
  s3 ls s3://test-bucket/

kubectl wait pod/pod-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl logs pod/pod-check
kubectl delete pod pod-check

# クリーンアップ
kubectl delete pod pod-a pod-b
