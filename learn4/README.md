# 認証情報を ConfigMap と Secret に分ける

learn3 の `minio.yaml` には、MinIO の管理者のユーザー名とパスワードが直接書かれていました。
このステップでは、ユーザー名を ConfigMap に、パスワードを Secret に移し、Deployment からは名前で参照します。

このステップの問いは次のひとつです。

> **Secret に入れたパスワードは、クラスタのどこに、どういう形で置かれているのか。**

新しく扱うリソースは ConfigMap と Secret です。

> learn3 と同じく、MinIO のイメージはもう配布されていません。この VM に残っているイメージで動かしています（[learn3](../learn3/README.md) の冒頭を参照）。

## 目次

- [前提条件](#前提条件)
- [1. 何を分けるのか](#1-何を分けるのか)
- [2. ConfigMap と Secret を作る](#2-configmap-と-secret-を作る)
- [3. Deployment を参照に切り替える](#3-deployment-を参照に切り替える)
- [4. Secret はどこにどう置かれているか](#4-secret-はどこにどう置かれているか)
- [5. 出力の読み方](#5-出力の読み方)
- [6. 落とし穴](#6-落とし穴)
- [演習](#演習)
- [クリーンアップ](#クリーンアップ)
- [まとめ](#まとめ)

## 前提条件

learn3 を終えて、クリーンアップをしていない状態から始めます。

- namespace `minio` に、learn3 の MinIO（Deployment `minio`、PVC `minio-pvc`、Service `minio`）が動いている
- PV `minio-pv` が `Bound`
- `test-bucket` に `pod-a.txt`・`pod-b.txt` が入っている（なくても進められます）

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn4 k3s-master:/home/ubuntu/
```

## 1. 何を分けるのか

learn3 の Deployment には、認証情報が値として書かれています。

```yaml
env:
  - name: MINIO_ROOT_USER
    value: "minioadmin"
  - name: MINIO_ROOT_PASSWORD
    value: "minioadmin"
```

この書き方には 2 つの問題があります。

1. **マニフェストを読める人に、パスワードが読める。**Git に入れれば履歴に残る
2. **設定を変えるたびに Deployment を書き換える。**アプリの定義と環境ごとの値が 1 つのファイルに混ざる

Kubernetes は、Pod に渡す値の置き場所として 2 種類のリソースを用意しています。

| リソース | 置くもの | このステップで置くもの |
|---|---|---|
| ConfigMap | 秘密でない設定値 | `root-user: minioadmin` |
| Secret | 秘密の値（パスワード、トークン、鍵） | `root-password: minioadmin` |

どちらも Key-Value の入れ物で、Pod へは環境変数かファイルとして渡します。
**違いは扱いの約束**です。Secret は `kubectl describe` で値を表示しない、アクセス権を ConfigMap と分けて絞れる、などの配慮があります。
ただし後で見るとおり、**暗号化はされていません。**

> `minioadmin` は学習用のダミー値です。

## 2. ConfigMap と Secret を作る

```yaml
# minio-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: minio-config
  namespace: minio
data:
  root-user: minioadmin
```

```yaml
# minio-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: minio
type: Opaque
stringData:
  root-password: minioadmin
```

Secret の `stringData` には平文で書けます。保存するときに Kubernetes が `data`（base64）に変換します。

```bash
# VM 内
cd /home/ubuntu/learn4
kubectl apply -f minio-configmap.yaml
kubectl apply -f minio-secret.yaml
kubectl describe configmap -n minio minio-config
kubectl describe secret -n minio minio-secret
```

```
Name:         minio-config
Namespace:    minio
...
Data
====
root-user:
----
minioadmin
```

```
Name:         minio-secret
Namespace:    minio
...
Type:  Opaque

Data
====
root-password:  10 bytes
```

ConfigMap は値をそのまま見せ、Secret は長さ（`minioadmin` の 10 バイト）だけを見せます。

## 3. Deployment を参照に切り替える

learn4 の `minio.yaml` は、learn3 のものと `env` だけが違います。apply する前に、何が変わるかを `kubectl diff` で見ます。

```bash
# VM 内
kubectl diff -f minio.yaml
```

```diff
         env:
         - name: MINIO_ROOT_USER
-          value: minioadmin
+          valueFrom:
+            configMapKeyRef:
+              key: root-user
+              name: minio-config
         - name: MINIO_ROOT_PASSWORD
-          value: minioadmin
+          valueFrom:
+            secretKeyRef:
+              key: root-password
+              name: minio-secret
```

`configMapKeyRef` と `secretKeyRef` は「この名前のリソースの、このキーの値を入れる」という指定です。

```bash
# VM 内
kubectl apply -f minio.yaml
kubectl rollout status deployment/minio -n minio
kubectl get pod -n minio
```

```
namespace/minio unchanged
persistentvolumeclaim/minio-pvc unchanged
deployment.apps/minio configured
service/minio unchanged
...
deployment "minio" successfully rolled out

NAME                     READY   STATUS      RESTARTS   AGE
minio-67df4b8b59-g7b4g   1/1     Running     0          12s
minio-7945684899-hbmpf   0/1     Completed   0          77s
```

Deployment の中身（Pod のひな形）が変わったので、Deployment は**新しい Pod を作ってから古い Pod を止めました**。
Pod 名の真ん中（ReplicaSet の識別子）が変わっています。Pod の中の環境変数を確かめます。

```bash
# VM 内
kubectl exec -n minio deploy/minio -- printenv MINIO_ROOT_USER MINIO_ROOT_PASSWORD
```

```
minioadmin
minioadmin
```

Pod から見える値は learn3 と同じです。変わったのは、値がどこから来るかだけです。
Mac のブラウザから `http://<VM の IP>:30901` に `minioadmin` / `minioadmin` でログインできます。

## 4. Secret はどこにどう置かれているか

### 4-1. API から見た姿: base64

```bash
# VM 内
kubectl get secret -n minio minio-secret -o yaml
```

```yaml
apiVersion: v1
data:
  root-password: bWluaW9hZG1pbg==
kind: Secret
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Secret","metadata":{"annotations":{},"name":"minio-secret","namespace":"minio"},"stringData":{"root-password":"minioadmin"},"type":"Opaque"}
  ...
```

`bWluaW9hZG1pbg==` は `minioadmin` の base64 で、`echo bWluaW9hZG1pbg== | base64 -d` で戻せます。
**base64 は文字の置き換えにすぎず、鍵なしで誰でも戻せます。**

さらに、`last-applied-configuration` の注釈に、`stringData` が**平文のまま**残っています。
`kubectl apply` は「前回 apply した内容」をこの注釈に保存するので、`stringData` で書いた値はここにそのまま入ります。

### 4-2. 保存先から見た姿: SQLite に平文

Kubernetes はリソースを etcd というデータベースに保存する、とよく説明されます。
k3s のノード 1 台の構成では、etcd の代わりに **SQLite**（1 つのファイルのデータベース）を使います。

```bash
# VM 内
sudo ls /var/lib/rancher/k3s/server/db/
sudo k3s etcd-snapshot ls
```

```
etcd  state.db  state.db-shm  state.db-wal
...
level=fatal msg="Error: see server log for details: etcd datastore disabled"
```

`state.db` の中で、Secret は `/registry/secrets/minio/minio-secret` という名前の行に入っています。
Python で読み取り専用で開き、読める文字列だけを抜き出すと次のようになりました。

```
/registry/secrets/minio/minio-secret 585 bytes
head: b'k8s\x00'
[..., '{"apiVersion":"v1",...,"stringData":{"root-password":"minioadmin"},...}', ..., 'root-password', 'minioadmin']
```

先頭の `k8s\x00` は Kubernetes のバイナリ形式（protobuf）の印です。その中に **`minioadmin` が base64 ですらない生の文字列で**入っています。
k3s は、起動オプション `--secrets-encryption` を付けないと Secret を暗号化しません。この環境では付けていません。

まとめると、パスワード `minioadmin` はこの VM の中で次の 3 か所から読めます。

| 場所 | 形 | 読める人 |
|---|---|---|
| `kubectl get secret -o yaml` の `data` | base64 | Secret を get する権限がある人 |
| 同じ出力の `last-applied-configuration` | 平文 | 同上 |
| `/var/lib/rancher/k3s/server/db/state.db` | 平文 | VM の root |

## 5. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| `kubectl describe secret` の `10 bytes` | 値の長さ。値そのものは出さない |
| `kubectl diff` の `-` と `+` | `-` がクラスタ上の今の状態、`+` が apply した後の状態 |
| `apply` の `configured` と `unchanged` | 中身が変わったリソースだけが `configured` になる |
| 古い Pod の `Completed` | 新しい Pod と入れ替わって正常終了した。すぐに消える |

## 6. 落とし穴

- **Secret を変えても、動いている Pod の環境変数は変わりません。**環境変数は Pod を作るときに一度だけ読まれます。
  この環境で Secret を `changed-pass` に変えて 5 秒待っても、Pod の `MINIO_ROOT_PASSWORD` は `minioadmin` のままでした。
  `kubectl rollout restart deployment/minio -n minio` で Pod を作り直すと、`changed-pass` になりました
- **learn4 の `minio.yaml` には Namespace も入っています。**`kubectl delete -f minio.yaml` をすると namespace `minio` ごと消え、
  中の ConfigMap と Secret も消えます。その後に `kubectl delete -f minio-secret.yaml` をすると `NotFound` になります
- **`stringData` で書いた値は `last-applied-configuration` に平文で残ります。**`kubectl create secret generic ... --from-literal` で作ると、この注釈は付きません

## 演習

1. `minio-secret.yaml` のパスワードを変えて apply し、`printenv` で Pod の値が変わらないことを確かめる。
   `rollout restart` の後に変わること、古いパスワードで Web 画面にログインできなくなることも確かめる。最後に元に戻す
2. `minio.yaml` の `secretKeyRef.key` を `root-pass` に変えて apply し、新しい Pod がどうなるか、古い Pod が止まるかを見る
3. Secret を `kubectl create secret generic minio-secret -n minio --from-literal=root-password=minioadmin --dry-run=client -o yaml` で作り、
   `last-applied-configuration` が付かないことを確かめる

## クリーンアップ

learn5 は、この MinIO と ConfigMap・Secret をそのまま使います。**learn5 に進むなら何も消しません。**
ここでやめるときは次のとおりです。

```bash
# VM 内
kubectl delete -f minio.yaml         # namespace ごと消え、ConfigMap と Secret も消える
kubectl delete pv minio-pv
sudo rm -rf /mnt/ssd/minio-storage   # バケットとオブジェクトも消す場合
```

## まとめ

- ConfigMap は秘密でない値、Secret は秘密の値の入れ物。Pod は名前とキーで参照する
- Secret の `data` は base64 で、暗号化ではない。k3s の SQLite には平文で入っている
- `kubectl apply` は `stringData` を `last-applied-configuration` に平文で残す
- 環境変数で渡した値は、Pod を作り直すまで変わらない
- 次の [learn5](../learn5/README.md) では、この Secret を Rust のプログラムからも使います
