# learn-kubernetes

Kubernetes の学習用リポジトリです。

## ディレクトリ構成

| ディレクトリ | 内容 |
|---|---|
| `learn1/` | 書籍「つくって、壊して、直して学ぶ Kubernetes入門」(高橋あおい著) のハンズオンで使用するマニフェストファイル |
| `learn2/` | Mac Mini 上に Multipass と k3s を使って Kubernetes コントロールプレーンを構築する手順。USB 接続の外付け SSD を PersistentVolume として Kubernetes から利用する設定も含む |
| `learn3/` | learn2 で構築したクラスタ上に MinIO (S3 互換オブジェクトストレージ) をデプロイする手順。StorageClass・PersistentVolume・PersistentVolumeClaim の関係を学ぶ |
| `learn4/` | learn3 の MinIO 構成をリファクタリングし、マニフェストにハードコードされていた認証情報を ConfigMap (ユーザー名) と Secret (パスワード) に分離する |
| `learn5/` | `aws-sdk-s3` crate を使った Rust プログラムを Kubernetes の Job として実行し、MinIO に対してバケット作成・アップロード・一覧取得・ダウンロードを行う |

## learn6 候補

| 案 | 内容 | 難易度 |
|---|---|---|
| A | **マルチノードクラスタ**: Multipass で VM をもう1台追加して k3s エージェントとして参加させ、Pod のスケジューリングとノード間ストレージの扱いを学ぶ | 中 |
| B | **Helm**: learn3 で手書きした `minio.yaml` を公式 Helm chart で置き換え、install / upgrade / rollback と values によるカスタマイズを学ぶ | 中 |
| C | **CronJob**: Kubernetes の CronJob リソースを使い、特定のデータを定期的に MinIO へバックアップする Job を組む | 中 |
| D | **Liveness / Readiness Probe**: MinIO および Rust Job に Probe を追加・調整し、障害時の挙動を意図的に引き起こして観察する | 低〜中 |
| E | **ResourceQuota / LimitRange**: namespace `minio` に CPU・メモリ上限を設定し、リソース超過時の挙動と QoS クラスを学ぶ | 低〜中 |