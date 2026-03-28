# ConfigMap と Secret で認証情報を管理する

learn3 でデプロイした MinIO の認証情報（ユーザー名・パスワード）は `minio.yaml` にハードコードされていました。
このドキュメントでは ConfigMap と Secret に分離し、マニフェストから機密情報を排除します。

---

## 目次

- [前提条件](#前提条件)
- [1. learn4 ディレクトリを VM にマウント](#1-learn4-ディレクトリを-vm-にマウント)
- [2. ConfigMap の作成](#2-configmap-の作成)
- [3. Secret の作成](#3-secret-の作成)
- [4. Deployment を更新](#4-deployment-を更新)
- [5. 動作確認](#5-動作確認)
- [6. Secret の内部表現を確認](#6-secret-の内部表現を確認)
- [クリーンアップ](#クリーンアップ)

---

## 前提条件

learn3 の手順が完了していること:

- MinIO が `minio` namespace で稼働中
- `sudo kubectl get pod -n minio` で `Running` になっている

---

## 1. learn4 ディレクトリを VM にマウント

```bash
multipass mount /path/to/learn-kubernetes/learn4 k3s-master:/home/ubuntu/learn4
```

`multipass mount` が使えない場合:

```bash
multipass transfer \
  minio-configmap.yaml minio-secret.yaml minio.yaml \
  k3s-master:/home/ubuntu/
```

---

## 2. ConfigMap の作成

**ConfigMap** は機密性のない設定値を Key-Value 形式で保存するリソースです。
Pod の環境変数やファイルとしてマウントして利用できます。

ここではユーザー名 (`root-user`) を ConfigMap に切り出します。

| フィールド | 値 | 説明 |
|---|---|---|
| `data.root-user` | `minioadmin` | MinIO 管理者ユーザー名 |

```bash
sudo kubectl apply -f /home/ubuntu/learn4/minio-configmap.yaml
sudo kubectl get configmap -n minio minio-config
```

内容を確認:

```bash
sudo kubectl describe configmap -n minio minio-config
```

---

## 3. Secret の作成

**Secret** は機密情報（パスワード・トークン・証明書など）を保存するリソースです。
ConfigMap と異なり、値は base64 エンコードされて etcd に格納されます。

ここではパスワード (`root-password`) を Secret に切り出します。
`stringData` を使うと平文で記述でき、Kubernetes が自動的に base64 エンコードします。

| フィールド | 値 | 説明 |
|---|---|---|
| `stringData.root-password` | `minioadmin` | MinIO 管理者パスワード |

```bash
sudo kubectl apply -f /home/ubuntu/learn4/minio-secret.yaml
sudo kubectl get secret -n minio minio-secret
```

---

## 4. Deployment を更新

learn3 の `minio.yaml` では環境変数を直接記述していました。

**変更前:**
```yaml
env:
  - name: MINIO_ROOT_USER
    value: "minioadmin"
  - name: MINIO_ROOT_PASSWORD
    value: "minioadmin"
```

**変更後:**
```yaml
env:
  - name: MINIO_ROOT_USER
    valueFrom:
      configMapKeyRef:
        name: minio-config
        key: root-user
  - name: MINIO_ROOT_PASSWORD
    valueFrom:
      secretKeyRef:
        name: minio-secret
        key: root-password
```

`configMapKeyRef` と `secretKeyRef` で ConfigMap・Secret のキーを参照しています。
Deployment を更新すると Pod が再起動し、新しい参照方式で環境変数が注入されます。

```bash
sudo kubectl apply -f /home/ubuntu/learn4/minio.yaml
```

Pod の再起動を確認:

```bash
sudo kubectl get pod -n minio -w
```

---

## 5. 動作確認

Pod が `Running` になったら、Web Console へのログインで認証情報が正しく渡されていることを確認します。

```bash
multipass info k3s-master | grep IPv4
```

`http://<IP>:30901` にアクセスし、ユーザー名 `minioadmin`・パスワード `minioadmin` でログインできれば正常です。

---

## 6. Secret の内部表現を確認

Secret の値が base64 エンコードされていることを確認します。

```bash
sudo kubectl get secret -n minio minio-secret -o yaml
```

出力例:

```yaml
data:
  root-password: bWluaW9hZG1pbg==
```

`bWluaW9hZG1pbg==` は `minioadmin` を base64 エンコードした値です。デコードして確認できます:

```bash
echo "bWluaW9hZG1pbg==" | base64 -d
# minioadmin
```

> **注意**: base64 は暗号化ではありません。Secret はアクセス権の制御（RBAC）によって保護するものです。
> 本番環境では Sealed Secrets や Vault など外部のシークレット管理ツールの利用を検討してください。

---

## クリーンアップ

```bash
sudo kubectl delete -f /home/ubuntu/learn4/minio.yaml
sudo kubectl delete -f /home/ubuntu/learn4/minio-secret.yaml
sudo kubectl delete -f /home/ubuntu/learn4/minio-configmap.yaml
sudo kubectl delete -f /home/ubuntu/learn3/minio-pv.yaml
sudo rm -rf /mnt/ssd/minio-storage
```
