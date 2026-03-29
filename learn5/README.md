# Rust から MinIO に接続する

`aws-sdk-s3` crate を使った Rust プログラムを Kubernetes の Job として実行し、MinIO に対してバケット作成・アップロード・一覧取得・ダウンロードを行います。
認証情報は learn4 で作成した ConfigMap・Secret を再利用します。

---

## 目次

- [前提条件](#前提条件)
- [1. learn5 ディレクトリを VM にマウント](#1-learn5-ディレクトリを-vm-にマウント)
- [2. Docker Engine のインストール](#2-docker-engine-のインストール)
- [3. Rust プログラムの概要](#3-rust-プログラムの概要)
- [4. Docker イメージのビルド](#4-docker-イメージのビルド)
- [5. k3s へのイメージのインポート](#5-k3s-へのイメージのインポート)
- [6. Job の実行](#6-job-の実行)
- [7. 結果の確認](#7-結果の確認)
- [クリーンアップ](#クリーンアップ)

---

## 前提条件

learn4 の手順が完了していること:

- MinIO が `minio` namespace で稼働中
- ConfigMap `minio-config` と Secret `minio-secret` が作成済み

---

## 1. learn5 ディレクトリを VM にマウント

```bash
multipass mount /path/to/learn-kubernetes/learn5 k3s-master:/home/ubuntu/learn5
```

`multipass mount` が使えない場合:

```bash
multipass transfer \
  Cargo.toml Dockerfile job.yaml \
  k3s-master:/home/ubuntu/learn5/
multipass transfer \
  src/main.rs \
  k3s-master:/home/ubuntu/learn5/src/
```

---

## 2. Docker Engine のインストール

> **Docker Desktop と Docker Engine の違い**
> Docker Desktop (Mac/Windows の GUI アプリ) は大企業での商用利用が有償ですが、
> Linux 上の Docker Engine は Apache 2.0 ライセンスで商用利用も無償です。

VM 内で実行します。

```bash
multipass shell k3s-master

# Docker Engine のインストール
sudo apt-get update
sudo apt-get install -y docker.io

# 起動・自動起動設定
sudo systemctl start docker
sudo systemctl enable docker

# ubuntu ユーザーを docker グループに追加 (sudo なしで実行可能にする)
sudo usermod -aG docker ubuntu
```

グループの変更を反映するためシェルを再起動します。

```bash
exit
multipass shell k3s-master

# 動作確認
docker version
```

---

## 3. Rust プログラムの概要

`src/main.rs` は以下の操作を順に実行します。

| 操作 | 説明 |
|---|---|
| バケット作成 | `BUCKET_NAME` 環境変数で指定したバケットを作成 |
| アップロード | `"Hello from Rust on Kubernetes!"` を `hello.txt` としてアップロード |
| 一覧取得 | バケット内のオブジェクト名とサイズを表示 |
| ダウンロード | `hello.txt` を取得して内容を標準出力に表示 |

接続先・認証情報は以下の環境変数で設定します。

| 環境変数 | 参照元 | 説明 |
|---|---|---|
| `MINIO_ENDPOINT` | job.yaml に直接記述 | MinIO の S3 API エンドポイント |
| `BUCKET_NAME` | job.yaml に直接記述 | 操作対象のバケット名 |
| `AWS_ACCESS_KEY_ID` | ConfigMap `minio-config` | MinIO ユーザー名 |
| `AWS_SECRET_ACCESS_KEY` | Secret `minio-secret` | MinIO パスワード |

---

## 4. Docker イメージのビルド

VM 内の learn5 ディレクトリでビルドします。
Dockerfile はマルチステージビルドを採用しており、ビルド環境 (`rust:slim`) と実行環境 (`debian:bookworm-slim`) を分離しています。

```bash
cd /home/ubuntu/learn5
docker build -t minio-rust-client:latest .
```

> **注意**: 初回ビルド時は Rust のコンパイルと依存クレートのダウンロードに数分かかります。

ビルド後にイメージを確認:

```bash
docker images minio-rust-client
```

---

## 5. k3s へのイメージのインポート

k3s は Docker とは独立した containerd を使用しているため、Docker でビルドしたイメージを k3s に認識させるにはインポートが必要です。

```bash
docker save minio-rust-client:latest | sudo k3s ctr images import -
```

インポートの確認:

```bash
sudo k3s ctr images ls | grep minio-rust-client
```

---

## 6. Job の実行

**Job** は1回限りの処理を実行するリソースです。Pod と異なり、処理が完了すると `Completed` 状態になります。

`job.yaml` では `imagePullPolicy: Never` を指定しており、レジストリからのプルを行わず、インポート済みのローカルイメージを使用します。

```bash
sudo kubectl apply -f /home/ubuntu/learn5/job.yaml
```

---

## 7. 結果の確認

Job と Pod の状態を確認します。

```bash
sudo kubectl get job -n minio minio-rust-client
sudo kubectl get pod -n minio -l job-name=minio-rust-client
```

Pod が `Completed` になったらログを確認します。

```bash
sudo kubectl logs -n minio -l job-name=minio-rust-client
```

期待される出力:

```
バケットを作成中: rust-bucket
完了
アップロード中: hello.txt
完了
オブジェクト一覧:
  - hello.txt (31 bytes)
ダウンロード中: hello.txt
内容: Hello from Rust on Kubernetes!
```

---

## クリーンアップ

```bash
sudo kubectl delete job -n minio minio-rust-client
```