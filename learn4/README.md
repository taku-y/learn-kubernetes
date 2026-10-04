# 認証情報を ConfigMap と Secret に分ける

learn3 の `rustfs.yaml` には、RustFS の管理者のアクセスキーとシークレットキー（ユーザー名とパスワードにあたるもの）が直接書かれていました。
このステップでは、アクセスキーを ConfigMap に、シークレットキーを Secret に移し、Deployment からは名前で参照します。

このステップの問いは次のひとつです。

> **Secret に入れたパスワードは、クラスタのどこに、どういう形で置かれているのか。**

新しく扱うリソースは ConfigMap と Secret です。

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

- namespace `rustfs` に、learn3 の RustFS（Deployment `rustfs`、PVC `rustfs-pvc`、Service `rustfs`）が動いている
- PV `rustfs-pv` が `Bound`
- `test-bucket` に `pod-a.txt`・`pod-b.txt` が入っている（なくても進められます）

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn4 k3s-master:/home/ubuntu/
```

## 1. 何を分けるのか

learn3 の Deployment には、認証情報が値として書かれています。

```yaml
env:
  - name: RUSTFS_ACCESS_KEY
    value: "rustfsadmin"
  - name: RUSTFS_SECRET_KEY
    value: "rustfsadmin"
```

この書き方には 2 つの問題があります。

1. **マニフェストを読める人に、パスワードが読める。**Git に入れれば履歴に残る
2. **設定を変えるたびに Deployment を書き換える。**アプリの定義と環境ごとの値が 1 つのファイルに混ざる

Kubernetes は、Pod に渡す値の置き場所として 2 種類のリソースを用意しています。

| リソース | 置くもの | このステップで置くもの |
|---|---|---|
| ConfigMap | 秘密でない設定値 | `access-key: rustfsadmin` |
| Secret | 秘密の値（パスワード、トークン、鍵） | `secret-key: rustfsadmin` |

どちらも Key-Value の入れ物で、Pod へは環境変数かファイルとして渡します。
**違いは扱いの約束**です。Secret は `kubectl describe` で値を表示しない、アクセス権を ConfigMap と分けて絞れる、などの配慮があります。
ただし後で見るとおり、**暗号化はされていません。**

> `rustfsadmin` は学習用のダミー値です（RustFS の既定値でもあります）。

## 2. ConfigMap と Secret を作る

```yaml
# rustfs-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rustfs-config
  namespace: rustfs
data:
  access-key: rustfsadmin
```

```yaml
# rustfs-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-secret
  namespace: rustfs
type: Opaque
stringData:
  secret-key: rustfsadmin
```

Secret の `stringData` には平文で書けます。保存するときに Kubernetes が `data`（base64）に変換します。

```bash
# VM 内
cd /home/ubuntu/learn4
kubectl apply -f rustfs-configmap.yaml
kubectl apply -f rustfs-secret.yaml
kubectl describe configmap -n rustfs rustfs-config
kubectl describe secret -n rustfs rustfs-secret
```

```
Name:         rustfs-config
Namespace:    rustfs
...
Data
====
access-key:
----
rustfsadmin
```

```
Name:         rustfs-secret
Namespace:    rustfs
...
Type:  Opaque

Data
====
secret-key:  11 bytes
```

ConfigMap は値をそのまま見せ、Secret は長さ（`rustfsadmin` の 11 バイト）だけを見せます。

## 3. Deployment を参照に切り替える

learn4 の `rustfs.yaml` は、learn3 のものと `env` の認証情報の 2 つ（とそのコメント）だけが違います。apply する前に、何が変わるかを `kubectl diff` で見ます。

```bash
# VM 内
kubectl diff -f rustfs.yaml
```

```diff
-  generation: 1
+  generation: 2
...
         - name: RUSTFS_ACCESS_KEY
-          value: rustfsadmin
+          valueFrom:
+            configMapKeyRef:
+              key: access-key
+              name: rustfs-config
         - name: RUSTFS_SECRET_KEY
-          value: rustfsadmin
+          valueFrom:
+            secretKeyRef:
+              key: secret-key
+              name: rustfs-secret
```

`configMapKeyRef` と `secretKeyRef` は「この名前のリソースの、このキーの値を入れる」という指定です。

```bash
# VM 内
kubectl apply -f rustfs.yaml
kubectl get pod -n rustfs     # 2 秒ごとに何度か
```

```
namespace/rustfs unchanged
persistentvolumeclaim/rustfs-pvc unchanged
deployment.apps/rustfs configured
service/rustfs unchanged
```

apply から 2 秒後と 8 秒後の `kubectl get pod -n rustfs` です。

```
NAME                      READY   STATUS    RESTARTS   AGE
rustfs-6bd8db54c-j887l    0/1     Running   0          2s
rustfs-7fd7648c57-zssdr   1/1     Running   0          2m46s
```

```
NAME                      READY   STATUS      RESTARTS   AGE
rustfs-6bd8db54c-j887l    1/1     Running     0          8s
rustfs-7fd7648c57-zssdr   0/1     Completed   0          2m52s
```

Deployment の中身（Pod のひな形）が変わったので、Deployment は**新しい Pod を作り、それが Ready になってから古い Pod を止めました**。
Pod 名の真ん中（ReplicaSet の識別子）が変わっています。
`diff` の `generation: 1 → 2` は、Deployment の定義が変わった回数です。Pod の中の環境変数を確かめます。

```bash
# VM 内
kubectl exec -n rustfs deploy/rustfs -- printenv RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY
```

```
rustfsadmin
rustfsadmin
```

Pod から見える値は learn3 と同じです。変わったのは、値がどこから来るかだけです。
Mac のブラウザから `http://<VM の IP>:30901/rustfs/console/` に `rustfsadmin` / `rustfsadmin` でログインできます。

## 4. Secret はどこにどう置かれているか

### 4-1. API から見た姿: base64

```bash
# VM 内
kubectl get secret -n rustfs rustfs-secret -o yaml
```

```yaml
apiVersion: v1
data:
  secret-key: cnVzdGZzYWRtaW4=
kind: Secret
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Secret","metadata":{"annotations":{},"name":"rustfs-secret","namespace":"rustfs"},"stringData":{"secret-key":"rustfsadmin"},"type":"Opaque"}
  ...
```

`cnVzdGZzYWRtaW4=` は `rustfsadmin` の base64 で、`echo cnVzdGZzYWRtaW4= | base64 -d` で戻せます。
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

`state.db` の中で、Secret は `kine` というテーブルの、`/registry/secrets/rustfs/rustfs-secret` という名前の行に入っています。
Python で読み取り専用で開き、読める文字列（8 文字以上）だけを抜き出します。

```bash
# VM 内
sudo python3 - <<'PY'
import sqlite3, re
db = sqlite3.connect("file:/var/lib/rancher/k3s/server/db/state.db?mode=ro", uri=True)
name, value = db.execute(
    "select name, value from kine where name = ? order by id desc limit 1",
    ("/registry/secrets/rustfs/rustfs-secret",)).fetchone()
print(name, len(value), "bytes")
print("head:", value[:4])
print([s.decode() for s in re.findall(rb"[ -~]{8,}", value)])
PY
```

```
/registry/secrets/rustfs/rustfs-secret 582 bytes
head: b'k8s\x00'
['rustfs-secret', ..., '{"apiVersion":"v1","kind":"Secret",...,"stringData":{"secret-key":"rustfsadmin"},"type":"Opaque"}', ..., 'secret-key', 'rustfsadmin']
```

先頭の `k8s\x00` は Kubernetes のバイナリ形式（protobuf）の印です。その中に **`rustfsadmin` が base64 ですらない生の文字列で**入っています。
k3s は、起動オプション `--secrets-encryption` を付けないと Secret を暗号化しません。この環境では付けていません。

まとめると、シークレットキー `rustfsadmin` はこの VM の中で次の 3 か所から読めます。

| 場所 | 形 | 読める人 |
|---|---|---|
| `kubectl get secret -o yaml` の `data` | base64 | Secret を get する権限がある人 |
| 同じ出力の `last-applied-configuration` | 平文 | 同上 |
| `/var/lib/rancher/k3s/server/db/state.db` | 平文 | VM の root |

## 5. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| `kubectl describe secret` の `11 bytes` | 値の長さ。値そのものは出さない |
| `kubectl diff` の `-` と `+` | `-` がクラスタ上の今の状態、`+` が apply した後の状態 |
| `apply` の `configured` と `unchanged` | 中身が変わったリソースだけが `configured` になる |
| 古い Pod の `Completed` | 新しい Pod と入れ替わって正常終了した。すぐに消える |

## 6. 落とし穴

- **Secret を変えても、動いている Pod の環境変数は変わりません。**環境変数は Pod を作るときに一度だけ読まれます。
  この環境で Secret を `changed-pass` に変えて 5 秒待っても、Pod の `RUSTFS_SECRET_KEY` は `rustfsadmin` のままでした。
  `kubectl rollout restart deployment/rustfs -n rustfs` で Pod を作り直すと `changed-pass` になり、
  古いキーで `aws s3 ls` をすると `SignatureDoesNotMatch` で失敗しました。新しいキーでは `test-bucket` が見えました
- **Deployment の入れ替えの間、RustFS が 2 つ同時に動きます。**3 の出力のとおり、新しい Pod が Ready になるまでの数秒間、
  2 つの Pod が同じ `rustfs-pvc` を開いています。今回はデータに問題は出ませんでした（`test-bucket` の中身は残りました）。
  データディレクトリを 1 つのプロセスだけが触る前提のソフトでは、`spec.strategy.type: Recreate`（古い Pod を止めてから新しい Pod を作る）にします
- **この環境の NFS では、ファイルのロックが使えません。**新しい Pod の `/logs/rustfs.log` に
  `Heal checkpoint persistence failed ... No locks available (os error 37)` が出ました。
  2 つの Pod のせいではなく、VM から `/mnt/ssd` のファイルにロックをかけるだけで同じエラーになります（[ssd-nfs.md](../ssd-nfs.md#7-落とし穴)）。
  RustFS の自己修復（heal）の途中経過を保存できないだけで、S3 の読み書きは通りました
- **learn4 の `rustfs.yaml` には Namespace も入っています。**`kubectl delete -f rustfs.yaml` をすると namespace `rustfs` ごと消え、
  中の ConfigMap と Secret も消えます。その後に `kubectl delete -f rustfs-secret.yaml` をすると `NotFound` になります
- **`stringData` で書いた値は `last-applied-configuration` に平文で残ります。**`kubectl create secret generic ... --from-literal` で作ると、この注釈は付きません

## 演習

1. `rustfs-secret.yaml` のシークレットキーを変えて apply し、`printenv` で Pod の値が変わらないことを確かめる。
   `rollout restart` の後に変わること、古いキーで Web 画面にログインできなくなることも確かめる。最後に元に戻す
2. `rustfs.yaml` の `secretKeyRef.key` を `secret` に変えて apply し、新しい Pod がどうなるか、古い Pod が止まるかを見る
3. Secret を `kubectl create secret generic rustfs-secret -n rustfs --from-literal=secret-key=rustfsadmin --dry-run=client -o yaml` で作り、
   `last-applied-configuration` が付かないことを確かめる

## クリーンアップ

learn5 は、この RustFS と ConfigMap・Secret をそのまま使います。**learn5 に進むなら何も消しません。**
ここでやめるときは次のとおりです。

```bash
# VM 内
kubectl delete -f rustfs.yaml         # namespace ごと消え、ConfigMap と Secret も消える
kubectl delete pv rustfs-pv
sudo rm -rf /mnt/ssd/rustfs-storage   # バケットとオブジェクトも消す場合
```

## まとめ

- ConfigMap は秘密でない値、Secret は秘密の値の入れ物。Pod は名前とキーで参照する
- Secret の `data` は base64 で、暗号化ではない。k3s の SQLite には平文で入っている
- `kubectl apply` は `stringData` を `last-applied-configuration` に平文で残す
- 環境変数で渡した値は、Pod を作り直すまで変わらない
- 次の [learn5](../learn5/README.md) では、この Secret を Rust のプログラムからも使います
