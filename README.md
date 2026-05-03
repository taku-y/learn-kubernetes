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
| `learn6/` | 公式 MinIO Helm Chart を使って MinIO をデプロイし、helm install / upgrade / rollback と values によるカスタマイズを学ぶ |

## learn7 候補

| 案 | 内容 | 難易度 |
|---|---|---|
| A | **CronJob**: Kubernetes の CronJob リソースを使い、Rust プログラムで MinIO 上のデータを定期的にバックアップする Job を組む | 低〜中 |
| B | **Liveness / Readiness Probe**: MinIO に Probe を設定し、障害時に Pod が自動再起動される挙動を観察する | 低〜中 |
| C | **Ingress**: Ingress Controller (Traefik / Nginx) を導入し、MinIO Console と S3 API をホスト名ベースでルーティングする | 中 |
| D | **HorizontalPodAutoscaler**: CPU 負荷に応じて Pod 数を自動スケールさせ、スケールアウト/インの挙動を観察する | 中 |
| E | **マルチノードクラスタ**: Multipass で VM をもう1台追加して k3s エージェントとして参加させ、Pod のスケジューリングとノード間ストレージの扱いを学ぶ | 中 |

## 参考情報

- [『Kubernetes完全ガイド（第二版）』 付録マニフェストのリポジトリ](https://github.com/MasayaAoyama/kubernetes-perfect-guide)
