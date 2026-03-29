# Helm で MinIO をデプロイする

## Helm とは

Helm は Kubernetes の**パッケージマネージャー**です。

learn3 では Namespace・PVC・Deployment・Service を個別の YAML ファイルとして手書きしました。アプリケーションが増えるほどこれらのファイルは増え、環境ごとの設定変更（本番/開発でのパスワード切り替えなど）も煩雑になります。

Helm はこの問題を以下の仕組みで解決します。

| 概念 | 説明 |
|---|---|
| **Chart** | 複数のマニフェストをテンプレートとしてまとめたパッケージ。`helm install` 一発でアプリ全体をデプロイできる |
| **Values** | Chart に渡す設定値。`values.yaml` に記述し、テンプレート内の変数を上書きする |
| **Release** | Chart を特定の設定でインストールした実体。名前を付けて管理される |
| **Revision** | Release のバージョン履歴。`helm upgrade` のたびに番号が増え、`helm rollback` で過去の状態に戻せる |

**Helm を使う意義:**
- コミュニティが公開している Chart を再利用でき、手書き YAML の管理コストを削減できる
- `upgrade` / `rollback` でデプロイの変更履歴を管理できる
- `values.yaml` の差し替えだけで環境ごとの設定を切り替えられる

> **注意:** Bitnami は 2025年8月28日以降、無料で利用できるイメージ・Chart の範囲を制限しました。
> このガイドでは公式 MinIO Helm Chart (`https://charts.min.io/`) を使用します。

---

## 目次

- [前提条件](#前提条件)
- [1. learn6 ディレクトリを VM にマウント](#1-learn6-ディレクトリを-vm-にマウント)
- [2. 既存リソースのクリーンアップ](#2-既存リソースのクリーンアップ)
- [3. Helm のインストール](#3-helm-のインストール)
- [4. PV の作成](#4-pv-の作成)
- [5. 公式 MinIO リポジトリの追加](#5-公式-minio-リポジトリの追加)
- [6. helm install でデプロイ](#6-helm-install-でデプロイ)
- [7. 動作確認](#7-動作確認)
- [8. helm upgrade で設定変更](#8-helm-upgrade-で設定変更)
- [9. helm rollback で元に戻す](#9-helm-rollback-で元に戻す)
- [クリーンアップ](#クリーンアップ)

---

## 前提条件

learn2 の手順が完了していること:

- k3s クラスタが稼働中
- StorageClass `local-ssd` が作成済み
- USB SSD が `/mnt/ssd` にマウント済み

---

## 1. learn6 ディレクトリを VM にマウント

```bash
multipass mount /path/to/learn-kubernetes/learn6 k3s-master:/home/ubuntu/learn6
```

`multipass mount` が使えない場合:

```bash
multipass transfer \
  pv.yaml values.yaml values-v2.yaml \
  k3s-master:/home/ubuntu/learn6/
```

---

## 2. 既存リソースのクリーンアップ

learn3・learn4 でデプロイした MinIO を削除します。Helm で新たにデプロイし直すため、既存リソースを事前に削除します。

```bash
# learn4 のリソースを削除 (learn4 をデプロイ済みの場合)
sudo kubectl delete -f /home/ubuntu/learn4/minio.yaml
sudo kubectl delete -f /home/ubuntu/learn4/minio-secret.yaml
sudo kubectl delete -f /home/ubuntu/learn4/minio-configmap.yaml

# learn3 の PV を削除
sudo kubectl delete -f /home/ubuntu/learn3/minio-pv.yaml

# データディレクトリを削除
sudo rm -rf /mnt/ssd/minio-storage
```

---

## 3. Helm のインストール

```bash
multipass shell k3s-master

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 動作確認
helm version
```

---

## 4. PV の作成

Helm が作成する PVC のバインド先となる PV を事前に作成します。

```bash
sudo mkdir -p /mnt/ssd/minio-helm-storage

sudo kubectl apply -f /home/ubuntu/learn6/pv.yaml
sudo kubectl get pv minio-helm-pv
```

---

## 5. 公式 MinIO リポジトリの追加

Helm Chart は**リポジトリ**で配布されています。ここでは MinIO 公式が提供するリポジトリを使います。

```bash
helm repo add minio-official https://charts.min.io/
helm repo update

# MinIO Chart の確認
helm search repo minio-official/minio
```

---

## 6. helm install でデプロイ

`values.yaml` を渡して MinIO をインストールします。

```bash
helm install minio minio-official/minio \
  --namespace minio \
  --create-namespace \
  -f /home/ubuntu/learn6/values.yaml
```

| オプション | 説明 |
|---|---|
| `minio` | Release 名 |
| `minio-official/minio` | 使用する Chart |
| `--namespace minio` | デプロイ先 namespace |
| `--create-namespace` | namespace が存在しない場合に作成 |
| `-f values.yaml` | カスタム設定ファイルを指定 |

インストール済み Release の確認:

```bash
helm list -n minio
```

---

## 7. 動作確認

```bash
# Pod の状態確認
sudo kubectl get pod -n minio -w

# PVC のバインド確認
sudo kubectl get pvc -n minio

# Service の確認
sudo kubectl get svc -n minio
```

VM の IP アドレスを確認してブラウザからアクセスします。

```bash
multipass info k3s-master | grep IPv4
```

| 用途 | URL |
|---|---|
| Web Console | `http://<IP>:30901` |
| S3 API | `http://<IP>:30900` |

---

## 8. helm upgrade で設定変更

`values-v2.yaml` ではリソース制限（CPU・メモリ）を追加しています。
`helm upgrade` を実行すると Revision が増え、Pod が新しい設定で再起動します。

```bash
helm upgrade minio minio-official/minio \
  --namespace minio \
  -f /home/ubuntu/learn6/values-v2.yaml
```

Revision が `2` に増えていることを確認:

```bash
helm list -n minio
```

Release の変更履歴を確認:

```bash
helm history minio -n minio
```

---

## 9. helm rollback で元に戻す

Revision 1 (リソース制限なし) に戻します。

```bash
helm rollback minio 1 -n minio
```

Revision が `3` になり、設定が Revision 1 の状態に戻っていることを確認:

```bash
helm history minio -n minio
sudo kubectl get pod -n minio -w
```

---

## クリーンアップ

```bash
helm uninstall minio -n minio
sudo kubectl delete -f /home/ubuntu/learn6/pv.yaml
sudo rm -rf /mnt/ssd/minio-helm-storage
sudo kubectl delete namespace minio
```

---

## トラブルシューティング

### helm install 後に Pod が Pending のまま

**原因1: メモリ不足**

```
0/1 nodes are available: 1 Insufficient memory.
```

`values.yaml` に `resources` を追加してメモリ要求を制限します（`values.yaml` には既に設定済み）。

再インストール:

```bash
helm uninstall minio -n minio
helm install minio minio-official/minio --namespace minio --create-namespace -f /home/ubuntu/learn6/values.yaml
```

---

**原因2: PV が Released 状態で PVC にバインドできない**

```
0/1 nodes are available: 1 node(s) didn't find available persistent volumes to bind.
```

#### claimRef とは

PV と PVC の **1対1の紐付け情報**です。PV 側に記録され、「この PV はどの PVC に予約されているか」を示します。

```
PV (minio-helm-pv)
  └── claimRef:
        namespace: minio
        name: minio        ← この PVC のためだけに確保
```

これにより、同じ `storageClass` の別の PVC が誤って接続されることを防ぎます。

#### PV のステータス遷移

| STATUS | 意味 |
|---|---|
| `Available` | 空き。どの PVC にもバインド可能 |
| `Bound` | PVC に紐付き済み |
| `Released` | PVC は削除されたが claimRef がまだ残っている |

#### なぜ自動でクリアされないのか

`Retain` ポリシーは**データを保護するための設計**です。誰かが明示的に確認・クリーンアップするまで PV を保持し続けます。自動でクリアされると、意図せずデータが上書きされるリスクがあります。

#### 対処手順

`helm uninstall` で PVC が削除されると、`Retain` ポリシーにより PV に古い `claimRef` が残り `Released` 状態になります。`Released` 状態の PV は新しい PVC からバインドできません。

PV の状態を確認:

```bash
kubectl get pv minio-helm-pv
```

`STATUS` が `Released` の場合、`claimRef` をクリアして `Available` に戻します:

```bash
kubectl patch pv minio-helm-pv -p '{"spec":{"claimRef": null}}'
```

その後、既存の Pod を削除して Deployment に再作成させます:

```bash
kubectl delete pod -n minio <pod名>
```

新しい Pod が `Running` になれば解消されています。
