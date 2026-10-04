# MinIO をマニフェストで手書きしてデプロイする

learn2 で作ったクラスタに、MinIO（S3 互換のオブジェクトストレージ）をデプロイします。
Namespace・PVC・Deployment・Service の 4 つを 1 つのファイルに手で書き、それぞれが何を担っているかを見ます。

このステップの問いは次のひとつです。

> **2 つの Pod が同時に書き込むとき、何がそれを受け止めているのか。**

新しく扱うリソースは Namespace・Deployment・Service です（PV・PVC は learn2 で扱いました）。

> **MinIO のイメージについて（2026-09-30 時点）**: MinIO 社は 2025 年 10 月に無償のコンテナイメージの配布をやめ、
> Docker Hub・Quay.io の `minio/minio` は取得できなくなっています（どちらも 401 を返すことを確認）。
> この教材の VM には以前取得した `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z` が残っているので、
> それを使って動かしています。**新しく作った VM では、このステップ以降の MinIO は起動できません。**
> 経緯と確認した URL は [notes.md](../notes.md) にあります。

## 目次

- [前提条件](#前提条件)
- [1. MinIO とは何か](#1-minio-とは何か)
- [2. minioyaml の 4 つのリソース](#2-minioyaml-の-4-つのリソース)
- [3. デプロイする](#3-デプロイする)
- [4. 2 つの Pod から同時に書き込む](#4-2-つの-pod-から同時に書き込む)
- [5. 出力の読み方](#5-出力の読み方)
- [6. 落とし穴](#6-落とし穴)
- [演習](#演習)
- [クリーンアップ](#クリーンアップ)
- [まとめ](#まとめ)

## 前提条件

learn2 を終えて、クラスタに次のものがある状態から始めます。

- ノード `k3s-master` が `Ready`
- StorageClass `local-ssd`
- USB SSD が VM の `/mnt/ssd` にマウントされている
- `kubectl` を `sudo` なしで使える（[vm-setup.md](../vm-setup.md#2-kubectl-と-helm-を-sudo-なしで使う)）

namespace `minio` と PV `minio-pv` は、まだ無い状態を想定します。

## 1. MinIO とは何か

MinIO は、Amazon S3 と同じ API でファイルを出し入れできるサーバーです。
ファイル（**オブジェクト**）は、**バケット**という入れ物の中に、**キー**（`pod-a.txt` のような名前）で置きます。
S3 用の道具（aws-cli、AWS の SDK）がそのまま使えるので、learn3 では aws-cli から、learn5 では Rust から使います。

learn2 では、Pod がファイルシステム（`/data`）に直接書きました。
このステップでは、Pod は MinIO に**ネットワーク越しに頼んで**書いてもらいます。
ディスクに触るのは MinIO の Pod だけです。

```
pod-a ─┐  HTTP (S3 API)                                  PVC minio-pvc → PV minio-pv
       ├───────────→ Service minio ──→ Pod minio ──→ /data ──→ /mnt/ssd/minio-storage
pod-b ─┘  minio.minio.svc:9000
```

## 2. minio.yaml の 4 つのリソース

`minio.yaml` は `---` で区切った 4 つのリソースを 1 つのファイルに入れています。
上から順に作られるので、namespace が先にできます。

| リソース | 名前 | 役割 |
|---|---|---|
| Namespace | `minio` | 他のリソースを入れる区画。以降の 3 つは `namespace: minio` に入る |
| PersistentVolumeClaim | `minio-pvc` | `local-ssd` を 50Gi 要求する。`minio-pv.yaml` の PV（`/mnt/ssd/minio-storage`）と結ばれる |
| Deployment | `minio` | MinIO のコンテナを 1 つ動かし続ける。Pod が消えたら作り直す |
| Service | `minio` | Pod への安定した入口。名前 `minio.minio.svc` と NodePort 30900・30901 を持つ |

これらは**名前とラベルで**つながっています。

| つなぎ目 | 参照元 | 参照先 |
|---|---|---|
| PVC を使う | Deployment の `volumes[].persistentVolumeClaim.claimName: minio-pvc` | PVC `minio-pvc` |
| Pod を見つける | Deployment の `selector.matchLabels: app: minio` | 自分が作る Pod の `labels: app: minio` |
| 通信を届ける | Service の `selector: app: minio` | ラベル `app: minio` を持つ Pod |

Service は Pod の名前を知りません。**ラベルが一致する Pod を探して、その IP に転送します。**
Pod が作り直されて名前や IP が変わっても、Service の名前は変わりません。

### Deployment の中身

| 項目 | 値 | 意味 |
|---|---|---|
| `image` | `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z` | 版を固定する。`latest` だと毎回取得しに行き、今は取得できない |
| `command` | `minio server /data --console-address :9001` | `/data` に保存し、Web 画面を 9001 番で出す |
| `env` | `MINIO_ROOT_USER`・`MINIO_ROOT_PASSWORD` = `minioadmin` | 管理者の認証情報。**学習用のダミー値**。learn4 で Secret に移す |
| `readinessProbe` | `/minio/health/ready` を 5 秒ごと、起動 10 秒後から | 応答できるまで Service の転送先に入れない |

### Service の 2 つのポート

| 名前 | Pod のポート | NodePort | 用途 |
|---|---|---|---|
| `api` | 9000 | 30900 | S3 API。クラスタ内からは `minio.minio.svc:9000` |
| `console` | 9001 | 30901 | Web 画面。Mac のブラウザから `http://<VM の IP>:30901` |

**NodePort** は、ノード（VM）の決まったポートで外から受け付ける Service の種類です。
使えるのは 30000〜32767 の範囲です。

## 3. デプロイする

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn3 k3s-master:/home/ubuntu/
```

```bash
# VM 内
cd /home/ubuntu/learn3
sudo mkdir -p /mnt/ssd/minio-storage
kubectl apply -f minio-pv.yaml
kubectl apply -f minio.yaml
```

```
persistentvolume/minio-pv created
namespace/minio created
persistentvolumeclaim/minio-pvc created
deployment.apps/minio created
service/minio created
```

2 秒後と、Ready になった後（apply から 14 秒）の様子です。

```bash
# VM 内
kubectl get pod,pvc -n minio
```

```
NAME                         READY   STATUS    RESTARTS   AGE
pod/minio-7945684899-hbmpf   0/1     Running   0          2s

NAME                              STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   ...
persistentvolumeclaim/minio-pvc   Bound    minio-pv   50Gi       RWO            local-ssd      ...
```

```bash
# VM 内
kubectl get all -n minio
```

```
NAME                         READY   STATUS    RESTARTS   AGE
pod/minio-7945684899-hbmpf   1/1     Running   0          14s

NAME            TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)                         AGE
service/minio   NodePort   10.43.29.65   <none>        9000:30900/TCP,9001:30901/TCP   14s

NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/minio   1/1     1            1           15s

NAME                               DESIRED   CURRENT   READY   AGE
replicaset.apps/minio-7945684899   1         1         1       15s
```

`kubectl get all` には、書いていない **ReplicaSet** も出ます。Deployment は Pod を直接作らず、
ReplicaSet（「この形の Pod を 1 つ保つ」係）を作り、ReplicaSet が Pod を作ります。
Pod 名の `minio-7945684899-hbmpf` は「Deployment 名 - ReplicaSet の識別子 - 乱数」です。

Service がどの Pod に転送しているかは EndpointSlice で見られます。

```bash
# VM 内
kubectl get endpointslices -n minio
```

```
NAME          ADDRESSTYPE   PORTS       ENDPOINTS     AGE
minio-stk7d   IPv4          9001,9000   10.42.0.110   16s
```

`10.42.0.110` が MinIO の Pod の IP です。ラベル `app: minio` で見つけた結果がここに入ります。

MinIO のログには、使っている版と、既定の認証情報への警告が出ます。

```bash
# VM 内
kubectl logs -n minio -l app=minio
```

```
Version: RELEASE.2024-12-18T13-15-44Z (go1.23.4 linux/arm64)

API: http://10.42.0.110:9000  http://127.0.0.1:9000
WebUI: http://10.42.0.110:9001 http://127.0.0.1:9001
...
WARN: Detected default credentials 'minioadmin:minioadmin', we recommend that you change these values with 'MINIO_ROOT_USER' and 'MINIO_ROOT_PASSWORD' environment variables
```

Mac のブラウザで `http://192.168.64.5:30901`（VM の IP は `multipass list` で確認）を開くと、MinIO の Web 画面が出ます。
ユーザー名・パスワードはどちらも `minioadmin` です。

## 4. 2 つの Pod から同時に書き込む

2 つのスクリプトは、どちらも `kubectl run` で aws-cli の Pod を一時的に作り、MinIO に S3 API で頼みます。
接続先は Service の名前 `http://minio.minio.svc:9000` です。Pod は `default` namespace に作られますが、
`<Service 名>.<namespace>.svc` の形で namespace をまたいで届きます。

| スクリプト | すること |
|---|---|
| `create-bucket.sh` | バケット `test-bucket` を作る |
| `test-concurrent-write.sh` | `pod-a` と `pod-b` を同時に起動し、それぞれが自分のホスト名を `pod-a.txt`・`pod-b.txt` として書く。終わったら一覧を出し、Pod を消す |

```bash
# VM 内
bash create-bucket.sh
bash test-concurrent-write.sh
```

```
pod/pod-a created
pod/pod-b created
両 Pod の起動リクエスト完了
pod/pod-a condition met
pod/pod-b condition met
--- Pod ステータス ---
NAME    READY   STATUS      RESTARTS   AGE
pod-a   0/1     Completed   0          3s
pod-b   0/1     Completed   0          3s
--- バケット内容 ---
pod/pod-check created
pod/pod-check condition met
2026-09-30 15:02:43          6 pod-a.txt
2026-09-30 15:02:43          6 pod-b.txt
...
```

2 つとも同じ秒に書かれ、どちらも 6 バイト（ホスト名 `pod-a` と改行）です。

### SSD の上ではどうなっているか

VM から MinIO のデータディレクトリを見ると、オブジェクトは**ファイルではなくディレクトリ**になっています。

```bash
# VM 内
find /mnt/ssd/minio-storage -not -path "*/.minio.sys*"
```

```
/mnt/ssd/minio-storage
/mnt/ssd/minio-storage/test-bucket
/mnt/ssd/minio-storage/test-bucket/pod-a.txt
/mnt/ssd/minio-storage/test-bucket/pod-a.txt/xl.meta
/mnt/ssd/minio-storage/test-bucket/pod-b.txt
/mnt/ssd/minio-storage/test-bucket/pod-b.txt/xl.meta
```

`xl.meta` は MinIO 独自の形式（先頭が `XL2`）で、小さいオブジェクトは中身もこの中に入ります。
**MinIO のデータディレクトリは MinIO を通して読み書きするもので、直接書き換えるものではありません。**

## 5. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| Pod の `READY 0/1` と `STATUS Running` | コンテナは動いているが、readinessProbe がまだ通っていない。Service の転送先に入っていない |
| `READY 1/1` | readinessProbe が通った。EndpointSlice に Pod の IP が載る |
| PVC が 2 秒で `Bound` | `WaitForFirstConsumer` でも、Deployment がすぐ Pod を作るので待ち時間はほぼない |
| Pod の `Completed` | `kubectl run --restart=Never` の Pod は、コマンドが終われば正常終了になる |
| `aws s3 ls` の日時 | UTC で表示される。日本時間では 9 時間足す |

## 6. 落とし穴

- **同時書き込みができるのは、MinIO が 1 つの Pod で受けているからです。**PV の `ReadWriteOnce` は
  「1 つの**ノード**から」という意味で、同じノードなら複数の Pod が同じ PVC をマウントできます。
  実際に、MinIO が動いている間に別の Pod から `minio-pvc` をマウントでき、`/data/test-bucket` が見えました。
  ただしその Pod が `xl.meta` を書き換えれば、MinIO のデータは壊れます
- **`kubectl run` は Pod を作った時点で戻ります。**書き込みの完了を待たずに一覧を取ると、まだ書かれていません。
  `test-concurrent-write.sh` は `kubectl wait` で完了を待ってから一覧を取ります
- **`create-bucket.sh` は 2 回目に失敗します。**同じ名前のバケットは作れず、Pod が `Error` になり、`kubectl wait` が 180 秒でタイムアウトします
  （⚠ 未検証: 2 回目の実行は試していません）。そのときは `kubectl delete pod pod-setup` で Pod を消します

## 演習

1. `minio.yaml` の Service の `selector` を `app: minio-typo` に変えて apply し、
   `kubectl get endpointslices -n minio` と `curl http://localhost:30900/minio/health/ready` がどう変わるかを見る
2. `readinessProbe` の `path` を `/minio/health/nothing` に変えて apply し、Pod の `READY` がどうなるかを見る
3. MinIO が動いている間に `kubectl delete pod -n minio -l app=minio` で Pod を消し、
   Deployment が別の名前の Pod を作ること、`test-bucket` の中身が残っていることを確かめる

## クリーンアップ

learn4 は、この MinIO をそのまま更新します。**learn4 に進むなら何も消しません。**
ここでやめるときは次のとおりです。

```bash
# VM 内
kubectl delete -f minio.yaml       # namespace ごと消える
kubectl delete -f minio-pv.yaml
sudo rm -rf /mnt/ssd/minio-storage   # バケットとオブジェクトも消す場合
```

## まとめ

- Deployment は ReplicaSet を通して Pod を保ち、Service はラベルで Pod を見つけて転送する
- クラスタ内からは `<Service 名>.<namespace>.svc`、外からは NodePort で届く
- 2 つの Pod の同時書き込みを受け止めているのは、ディスクではなく MinIO の Pod 1 つ
- `ReadWriteOnce` は Pod 単位ではなくノード単位の制限
- 次の [learn4](../learn4/README.md) では、この Deployment に直書きした認証情報を ConfigMap と Secret に移します
