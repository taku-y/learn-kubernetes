# MinIO を Kubernetes 上にデプロイする

learn2 で構築した k3s クラスタ上に MinIO をデプロイします。
MinIO は S3 互換 API を提供するオブジェクトストレージで、複数の Pod からの同時アクセスに対応します。

---

## 前提条件

- learn2 の手順で k3s クラスタが構築済みであること
- StorageClass `local-ssd` が作成済みであること
- USB SSD が `/mnt/ssd` にマウント済みであること

---

## 1. ストレージディレクトリの作成

VM 内で MinIO 用のデータディレクトリを作成します。

```bash
multipass shell k3s-master
sudo mkdir -p /mnt/ssd/minio-storage
```

---

## 2. PersistentVolume の作成

MinIO 専用の PV を作成します (`minio-pv.yaml`)。

| フィールド | 値 | 説明 |
|---|---|---|
| `capacity.storage` | `50Gi` | MinIO に割り当てるストレージ容量 |
| `storageClassName` | `local-ssd` | learn2 で作成した StorageClass |
| `local.path` | `/mnt/ssd/minio-storage` | VM 内のデータディレクトリ |

```bash
sudo kubectl apply -f minio-pv.yaml
sudo kubectl get pv minio-pv
```

---

## 3. Namespace・Deployment・Service のデプロイ

`minio.yaml` に以下のリソースをまとめています。

| リソース | 内容 |
|---|---|
| Namespace | `minio` |
| Deployment | MinIO コンテナ (replicas: 1) |
| Service | NodePort で API (30900) と Console (30901) を公開 |

### 環境変数

| 変数名 | デフォルト値 | 説明 |
|---|---|---|
| `MINIO_ROOT_USER` | `minioadmin` | 管理者ユーザー名 |
| `MINIO_ROOT_PASSWORD` | `minioadmin` | 管理者パスワード |

> **注意**: 本番環境では必ずパスワードを変更してください。

```bash
sudo kubectl apply -f minio-pvc.yaml
sudo kubectl apply -f minio.yaml
```

---

## 4. 起動確認

```bash
# Pod の状態確認
sudo kubectl get pod -n minio -w

# PVC のバインド確認
sudo kubectl get pvc -n minio

# Service の確認
sudo kubectl get svc -n minio
```

正常な場合の出力例:

```
NAME                     READY   STATUS    RESTARTS   AGE
minio-xxxxxxxxxx-xxxxx   1/1     Running   0          1m
```

---

## 5. Web Console へのアクセス

VM の IP アドレスを確認します。

```bash
multipass info k3s-master | grep IPv4
# 例: 192.168.64.10
```

Mac のブラウザから以下の URL にアクセスします。

| 用途 | URL |
|---|---|
| Web Console | `http://192.168.64.10:30901` |
| S3 API | `http://192.168.64.10:30900` |

ユーザー名 `minioadmin`、パスワード `minioadmin` でログインできます。

---

## 6. 複数 Pod からのアクセス確認

MinIO の S3 API を通じて複数の Pod から同時に読み書きできることを確認します。

### 6-1. テスト用 Pod を 2 つ起動

```bash
# Pod A を起動
sudo kubectl run pod-a --image=amazon/aws-cli --restart=Never --rm -it -- \
  --endpoint-url http://minio.minio.svc:9000 \
  --no-sign-request \
  s3 mb s3://test-bucket

# Pod B からも同じバケットに書き込む
sudo kubectl run pod-b --image=amazon/aws-cli --restart=Never --rm -it -- \
  --endpoint-url http://minio.minio.svc:9000 \
  --no-sign-request \
  s3 cp /etc/hostname s3://test-bucket/pod-b.txt
```

### 6-2. aws-cli で操作する場合の環境変数

```bash
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_DEFAULT_REGION=us-east-1
```

---

## 7. ログの確認

```bash
sudo kubectl logs -n minio -l app=minio -f
```

---

## トラブルシューティング

### Pod が起動しない

```bash
sudo kubectl describe pod -n minio -l app=minio
sudo kubectl logs -n minio -l app=minio
```

### PVC が Pending のまま

`WaitForFirstConsumer` モードのため、Pod がスケジュールされるまで Pending は正常です。
Deployment を apply した後に自動的に Bound になります。

```bash
sudo kubectl get pvc -n minio
sudo kubectl get pv minio-pv
```

### Console にアクセスできない

VM の IP アドレスと NodePort を確認してください。

```bash
multipass info k3s-master | grep IPv4
sudo kubectl get svc -n minio
```

---

## クリーンアップ

```bash
sudo kubectl delete -f minio.yaml
sudo kubectl delete -f minio-pvc.yaml
sudo kubectl delete -f minio-pv.yaml

# VM 内のデータも削除する場合
sudo rm -rf /mnt/ssd/minio-storage
```
