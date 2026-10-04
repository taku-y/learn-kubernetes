# learn-kubernetes

Kubernetes の学習用リポジトリです。
知らない用語（PV、PVC、StorageClass、Chart など）は [用語集](glossary.md) にまとめてあります。

> **状態: learn6 まで実装**。learn2〜learn6 は、作業規約（[CLAUDE.md](CLAUDE.md)）に合わせて 2026-09-30 に README を書き直し、
> 同じ日に VM 上で実行し直した出力を載せています。learn1 は書籍のハンズオンの記録で、再実行していません。
>
> **MinIO のイメージについて**: MinIO は 2025 年 10 月に無償のコンテナイメージの配布をやめ、2026-09-30 の時点で
> `minio/minio`・`minio/mc` は取得できません。learn3〜learn6 は、この教材の VM に残っているイメージで動かしています。
> 新しい VM では learn3 以降の MinIO は起動できません。経緯は [notes.md](notes.md) にあります。

## 目次

- [ステップ](#ステップ)
- [learn7 候補](#learn7-候補)
- [リポジトリ内のファイル](#リポジトリ内のファイル)
- [参考情報](#参考情報)
- [作業ログ](#作業ログ)

## ステップ

| ステップ | 内容 |
|---|---|
| [learn1](learn1/README.md) | 書籍「つくって、壊して、直して学ぶ Kubernetes入門」(高橋あおい著) のハンズオンで使用するマニフェストファイル |
| [learn2](learn2/README.md) | Mac Mini 上に Multipass と k3s を使って Kubernetes コントロールプレーンを構築する手順。USB 接続の外付け SSD を PersistentVolume として Kubernetes から利用する設定も含む |
| [learn3](learn3/README.md) | learn2 で構築したクラスタ上に MinIO (S3 互換オブジェクトストレージ) をデプロイする手順。StorageClass・PersistentVolume・PersistentVolumeClaim の関係を学ぶ |
| [learn4](learn4/README.md) | learn3 の MinIO 構成をリファクタリングし、マニフェストにハードコードされていた認証情報を ConfigMap (ユーザー名) と Secret (パスワード) に分離する |
| [learn5](learn5/README.md) | `aws-sdk-s3` crate を使った Rust プログラムを Kubernetes の Job として実行し、MinIO に対してバケット作成・アップロード・一覧取得・ダウンロードを行う |
| [learn6](learn6/README.md) | learn3 で手書きした MinIO のマニフェストを公式 Helm chart で置き換え、install / upgrade / rollback と values によるカスタマイズを学ぶ |

## learn7 候補

| 案 | 内容 | 難易度 |
|---|---|---|
| A | **CronJob**: Kubernetes の CronJob リソースを使い、Rust プログラムで MinIO 上のデータを定期的にバックアップする Job を組む | 低〜中 |
| B | **Liveness / Readiness Probe**: MinIO に Probe を設定し、障害時に Pod が自動再起動される挙動を観察する | 低〜中 |
| C | **Ingress**: Ingress Controller (Traefik / Nginx) を導入し、MinIO Console と S3 API をホスト名ベースでルーティングする | 中 |
| D | **HorizontalPodAutoscaler**: CPU 負荷に応じて Pod 数を自動スケールさせ、スケールアウト/インの挙動を観察する | 中 |
| E | **マルチノードクラスタ**: Multipass で VM をもう1台追加して k3s エージェントとして参加させ、Pod のスケジューリングとノード間ストレージの扱いを学ぶ | 中 |

## リポジトリ内のファイル

| ファイル | 中身 |
|---|---|
| [CLAUDE.md](CLAUDE.md) | 作業規約 |
| [glossary.md](glossary.md) | 用語集。ステップをまたいで使う用語の意味と、この教材での実例 |
| [notes.md](notes.md) | 確認したバージョン・API・詰まった点（確認日と URL つき） |
| [vm-setup.md](vm-setup.md) | ファイルを VM に持ち込む方法と、コマンドの実行場所（learn2 以降で共通） |
| [ssd-nfs.md](ssd-nfs.md) | Mac の USB SSD を NFS で VM の `/mnt/ssd` に見せる手順（learn2 で行い、learn3 以降の PV が使う） |
| `learnN/` | 各ステップ。本体は `learnN/README.md` |
| `log/` | 作業ログ |

## 参考情報

- [『Kubernetes完全ガイド（第二版）』 付録マニフェストのリポジトリ](https://github.com/MasayaAoyama/kubernetes-perfect-guide)

## 作業ログ

| 日付 | 内容 |
|---|---|
| [20261004](log/20261004.md) | MinIO の代わりに RustFS を調べ、採用を決めた。learn3 の RustFS 版を作り始めた。learn6 の MinIO の削除は残タスク |
| [20260930](log/20260930.md) | 作業規約（CLAUDE.md）を定め、learn1 の README と用語集を足した。learn2〜learn6 を VM で実行し直し、README を書き直した。MinIO のイメージの配布終了を見つけた |
