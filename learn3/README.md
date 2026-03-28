# MinIO を Kubernetes 上にデプロイする

learn2 で構築した k3s クラスタ上に MinIO をデプロイします。
MinIO は S3 互換 API を提供するオブジェクトストレージで、複数の Pod からの同時アクセスに対応します。

---

## 目次

- [前提条件](#前提条件)
- [1. learn3 ディレクトリを VM にマウント](#1-learn3-ディレクトリを-vm-にマウント)
- [2. ストレージディレクトリの作成 (MinIO 用)](#2-ストレージディレクトリの作成-minio-用)
- [3. MinIO の PersistentVolume を作成](#3-minio-の-persistentvolume-を作成)
- [4. Namespace・PVC・Deployment・Service のデプロイ](#4-namespacepvcdeploymentservice-のデプロイ)
- [5. 起動確認](#5-起動確認)
- [6. Web Console へのアクセス](#6-web-console-へのアクセス)
- [7. 複数 Pod からの同時アクセス確認](#7-複数-pod-からの同時アクセス確認)
- [8. ログの確認](#8-ログの確認)
- [トラブルシューティング](#トラブルシューティング)
- [クリーンアップ](#クリーンアップ)

---

## 前提条件

learn2 の手順が完了していること:

- k3s クラスタが稼働中 (`sudo kubectl get nodes` で `Ready` になっている)
- StorageClass `local-ssd` が作成済み
- USB SSD が `/mnt/ssd` にマウント済み

---

## 1. learn3 ディレクトリを VM にマウント

このリポジトリ内の YAML ファイルを VM 内から直接使用するために、learn3 ディレクトリを VM にマウントします。
これにより、`kubectl apply -f` 実行時にファイルを VM へ個別にコピーする手間が省けます。

### 1-1. multipass mount を試みる

```bash
# Mac 側で実行 (learn3 ディレクトリのパスは環境に合わせて変更)
multipass mount /path/to/learn-kubernetes/learn3 k3s-master:/home/ubuntu/learn3
```

マウント確認:

```bash
multipass shell k3s-master
ls /home/ubuntu/learn3
# yaml ファイル一覧が表示されれば OK
```

> **注意**: macOS Sequoia + Multipass (qemu driver) 環境では `multipass mount` が動作しない場合があります。
> その場合は以下の代替手段を使用してください。

### 1-2. multipass mount が使えない場合: ファイルを転送する

`multipass transfer` でファイルを VM へコピーできます。

```bash
# learn3 ディレクトリ内の yaml ファイルをまとめて VM へ転送
multipass transfer \
  minio-pv.yaml minio.yaml \
  k3s-master:/home/ubuntu/
```

VM 内でのパスは `/home/ubuntu/` になります。

### 1-3. マウント状態の確認

```bash
multipass info k3s-master
# Mounts セクションにマウント情報が表示されれば OK
```

---

## 2. ストレージディレクトリの作成 (MinIO 用)

VM 内で MinIO 用のデータディレクトリを作成します。

```bash
multipass shell k3s-master
sudo mkdir -p /mnt/ssd/minio-storage
```

---

## 3. MinIO の PersistentVolume を作成

MinIO 専用の PV を作成します (`minio-pv.yaml`)。

| フィールド | 値 | 説明 |
|---|---|---|
| `capacity.storage` | `50Gi` | MinIO に割り当てるストレージ容量 |
| `storageClassName` | `local-ssd` | learn2 で作成した StorageClass |
| `local.path` | `/mnt/ssd/minio-storage` | VM 内のデータディレクトリ |

```bash
sudo kubectl apply -f /home/ubuntu/learn3/minio-pv.yaml
sudo kubectl get pv minio-pv
```

---

## 4. Namespace・PVC・Deployment・Service のデプロイ

`minio.yaml` に以下のリソースをまとめています。ファイル内の定義順に apply されるため、Namespace → PVC → Deployment → Service の順で作成されます。

| リソース | 内容 |
|---|---|
| Namespace | `minio` |
| PersistentVolumeClaim | MinIO 用ストレージ要求 (50Gi) |
| Deployment | MinIO コンテナ (replicas: 1) |
| Service | NodePort で API (30900) と Console (30901) を公開 |

### 環境変数

| 変数名 | デフォルト値 | 説明 |
|---|---|---|
| `MINIO_ROOT_USER` | `minioadmin` | 管理者ユーザー名 |
| `MINIO_ROOT_PASSWORD` | `minioadmin` | 管理者パスワード |

> **注意**: 本番環境では必ずパスワードを変更してください。

```bash
sudo kubectl apply -f /home/ubuntu/learn3/minio.yaml
```

---

## 5. 起動確認

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

## 6. Web Console へのアクセス

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

## 7. 複数 Pod からの同時アクセス確認

MinIO の S3 API を通じて複数の Pod から同時に書き込めることを確認します。

### 7-1. バケットを作成

`create-bucket.sh` を実行します。

```bash
bash /home/ubuntu/learn3/create-bucket.sh
```

### 7-2. pod-a と pod-b を同時に起動して書き込む

`test-concurrent-write.sh` を実行します。`&` でバックグラウンド実行することで2つの Pod をほぼ同時に起動し、`wait` で両方の完了を待ちます。完了後に結果確認とクリーンアップも行います。

```bash
bash /home/ubuntu/learn3/test-concurrent-write.sh
```

期待される出力:

```
両 Pod の起動リクエスト完了
--- Pod ステータス ---
NAME    READY   STATUS      RESTARTS   AGE
pod-a   0/1     Completed   0          Xs
pod-b   0/1     Completed   0          Xs
--- バケット内容 ---
... pod-a.txt
... pod-b.txt
```

---

## 8. ログの確認

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

### multipass mount が失敗する

qemu driver 使用時に `multipass mount` が動作しない場合は `multipass transfer` でファイルを転送してください。

```bash
cd /path/to/learn-kubernetes/learn3
multipass transfer \
  minio-pv.yaml minio.yaml \
  k3s-master:/home/ubuntu/
```

---

## クリーンアップ

```bash
sudo kubectl delete -f /home/ubuntu/learn3/minio.yaml
sudo kubectl delete -f /home/ubuntu/learn3/minio-pv.yaml

# VM 内のデータも削除する場合
sudo rm -rf /mnt/ssd/minio-storage
```
