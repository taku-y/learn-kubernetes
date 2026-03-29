# learn-kubernetes

Kubernetes の学習用リポジトリです。

## ディレクトリ構成

| ディレクトリ | 内容 |
|---|---|
| `learn1/` | 書籍「つくって、壊して、直して学ぶ Kubernetes入門」(高橋あおい著) のハンズオンで使用するマニフェストファイル |
| `learn2/` | Mac Mini 上に Multipass と k3s を使って Kubernetes コントロールプレーンを構築する手順。USB 接続の外付け SSD を PersistentVolume として Kubernetes から利用する設定も含む |
| `learn3/` | learn2 で構築したクラスタ上に MinIO (S3 互換オブジェクトストレージ) をデプロイする手順。StorageClass・PersistentVolume・PersistentVolumeClaim の関係を学ぶ |
| `learn4/` | learn3 の MinIO 構成をリファクタリングし、マニフェストにハードコードされていた認証情報を ConfigMap (ユーザー名) と Secret (パスワード) に分離する |