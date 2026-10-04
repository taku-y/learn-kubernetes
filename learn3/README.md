# RustFS をマニフェストで手書きしてデプロイする

learn2 で作ったクラスタに、RustFS（S3 互換のオブジェクトストレージ）をデプロイします。
Namespace・PVC・Deployment・Service の 4 つを 1 つのファイルに手で書き、それぞれが何を担っているかを見ます。

このステップの問いは次のひとつです。

> **2 つの Pod が同時に書き込むとき、何がそれを受け止めているのか。**

新しく扱うリソースは Namespace・Deployment・Service です（PV・PVC は learn2 で扱いました）。

> **MinIO から RustFS に替えた理由（2026-10-04）**: この教材は当初 MinIO を使っていました。MinIO 社は 2025 年 10 月に無償のコンテナイメージの配布をやめ、
> 2026-09-30 の時点で `minio/minio` は取得できなくなっていたため、Apache-2.0 で配布が続いている RustFS に替えました。
> 経緯と確認した URL は [notes.md](../notes.md) にあります。

## 目次

- [前提条件](#前提条件)
- [1. RustFS とは何か](#1-rustfs-とは何か)
- [2. rustfsyaml の 4 つのリソース](#2-rustfsyaml-の-4-つのリソース)
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
- USB SSD が VM の `/mnt/ssd` にマウントされている（[ssd-nfs.md](../ssd-nfs.md)）
- `kubectl` を `sudo` なしで使える（[vm-setup.md](../vm-setup.md#2-kubectl-と-helm-を-sudo-なしで使う)）

namespace `rustfs` と PV `rustfs-pv` は、まだ無い状態を想定します。
NodePort 30900・30901 を他の Service が使っていないことも前提です（`kubectl get svc -A` で確かめられます）。

## 1. RustFS とは何か

RustFS は、Amazon S3 と同じ API でファイルを出し入れできるサーバーです。Rust で書かれていて、ライセンスは Apache-2.0 です。
ファイル（**オブジェクト**）は、**バケット**という入れ物の中に、**キー**（`pod-a.txt` のような名前）で置きます。
S3 用の道具（aws-cli、AWS の SDK）がそのまま使えるので、learn3 では aws-cli から、learn5 では Rust から使います。

イメージは RustFS の開発元が Docker Hub で配布している `rustfs/rustfs` です。このステップでは 2026-10-03 に出た `1.0.1` に固定します。
イメージの中では、`rustfs` というユーザー（UID 10001）でサーバーが動きます。

learn2 では、Pod がファイルシステム（`/data`）に直接書きました。
このステップでは、Pod は RustFS に**ネットワーク越しに頼んで**書いてもらいます。
ディスクに触るのは RustFS の Pod だけです。

```
pod-a ─┐  HTTP (S3 API)                                     PVC rustfs-pvc → PV rustfs-pv
       ├────────────→ Service rustfs ──→ Pod rustfs ──→ /data ──→ /mnt/ssd/rustfs-storage
pod-b ─┘  rustfs.rustfs.svc:9000
```

## 2. rustfs.yaml の 4 つのリソース

`rustfs.yaml` は `---` で区切った 4 つのリソースを 1 つのファイルに入れています。
上から順に作られるので、namespace が先にできます。PV は別のファイル `rustfs-pv.yaml` にあります。

| リソース | 名前 | 役割 |
|---|---|---|
| Namespace | `rustfs` | 他のリソースを入れる区画。以降の 3 つは `namespace: rustfs` に入る |
| PersistentVolumeClaim | `rustfs-pvc` | `local-ssd` を 50Gi 要求する。`rustfs-pv.yaml` の PV（`/mnt/ssd/rustfs-storage`）と結ばれる |
| Deployment | `rustfs` | RustFS のコンテナを 1 つ動かし続ける。Pod が消えたら作り直す |
| Service | `rustfs` | Pod への安定した入口。名前 `rustfs.rustfs.svc` と NodePort 30900・30901 を持つ |

これらは**名前とラベルで**つながっています。

| つなぎ目 | 参照元 | 参照先 |
|---|---|---|
| PVC を使う | Deployment の `volumes[].persistentVolumeClaim.claimName: rustfs-pvc` | PVC `rustfs-pvc` |
| Pod を見つける | Deployment の `selector.matchLabels: app: rustfs` | 自分が作る Pod の `labels: app: rustfs` |
| 通信を届ける | Service の `selector: app: rustfs` | ラベル `app: rustfs` を持つ Pod |

Service は Pod の名前を知りません。**ラベルが一致する Pod を探して、その IP に転送します。**
Pod が作り直されて名前や IP が変わっても、Service の名前は変わりません。

### Deployment の中身

| 項目 | 値 | 意味 |
|---|---|---|
| `image` | `rustfs/rustfs:1.0.1` | 版を固定する。`latest` だと、取得した日によって中身が変わる |
| `env` の `RUSTFS_VOLUMES` | `/data` | データを置くディレクトリ。`volumeMounts` の `mountPath` と合わせる |
| `env` の `RUSTFS_CONSOLE_ENABLE` | `true` | Web 画面を 9001 番で出す |
| `env` の `RUSTFS_ACCESS_KEY`・`RUSTFS_SECRET_KEY` | `rustfsadmin` | 管理者の認証情報。**学習用のダミー値**。learn4 で ConfigMap と Secret に移す |
| `readinessProbe` | `/health/ready` を 5 秒ごと、起動 5 秒後から | 応答できるまで Service の転送先に入れない |

`command` は書いていません。イメージに入っている既定の起動コマンド（`rustfs`）が、`RUSTFS_` で始まる環境変数を読みます。

### Service の 2 つのポート

| 名前 | Pod のポート | NodePort | 用途 |
|---|---|---|---|
| `api` | 9000 | 30900 | S3 API。クラスタ内からは `rustfs.rustfs.svc:9000` |
| `console` | 9001 | 30901 | Web 画面。Mac のブラウザから `http://<VM の IP>:30901/rustfs/console/` |

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
sudo mkdir -p /mnt/ssd/rustfs-storage
kubectl apply -f rustfs-pv.yaml
kubectl apply -f rustfs.yaml
```

```
persistentvolume/rustfs-pv created
namespace/rustfs created
persistentvolumeclaim/rustfs-pvc created
deployment.apps/rustfs created
service/rustfs created
```

2 秒後と、Ready になった後（apply から 9 秒）の様子です。

```bash
# VM 内
kubectl get pod,pvc -n rustfs
```

```
NAME                          READY   STATUS    RESTARTS   AGE
pod/rustfs-7fd7648c57-zssdr   0/1     Running   0          2s

NAME                               STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS   ...
persistentvolumeclaim/rustfs-pvc   Bound    rustfs-pv   50Gi       RWO            local-ssd      ...
```

```bash
# VM 内
kubectl get all -n rustfs
```

```
NAME                          READY   STATUS    RESTARTS   AGE
pod/rustfs-7fd7648c57-zssdr   1/1     Running   0          9s

NAME             TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)                         AGE
service/rustfs   NodePort   10.43.108.39   <none>        9000:30900/TCP,9001:30901/TCP   9s

NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rustfs   1/1     1            1           9s

NAME                                DESIRED   CURRENT   READY   AGE
replicaset.apps/rustfs-7fd7648c57   1         1         1       9s
```

`kubectl get all` には、書いていない **ReplicaSet** も出ます。Deployment は Pod を直接作らず、
ReplicaSet（「この形の Pod を 1 つ保つ」係）を作り、ReplicaSet が Pod を作ります。
Pod 名の `rustfs-7fd7648c57-zssdr` は「Deployment 名 - ReplicaSet の識別子 - 乱数」です。

Service がどの Pod に転送しているかは EndpointSlice で見られます。

```bash
# VM 内
kubectl get endpointslices -n rustfs
```

```
NAME           ADDRESSTYPE   PORTS       ENDPOINTS     AGE
rustfs-5kwk2   IPv4          9001,9000   10.42.0.129   9s
```

`10.42.0.129` が RustFS の Pod の IP です。ラベル `app: rustfs` で見つけた結果がここに入ります。

readinessProbe が見ている `/health/ready` は、NodePort 経由で VM から直接たたけます。

```bash
# VM 内
curl -s http://localhost:30900/health/ready
```

```
{"status":"ok","service":"rustfs-endpoint",...,"version":"1.0.1","ready":true,"details":{"storage":{"status":"connected","ready":true,...
```

### ログは 2 か所に出る

`kubectl logs` に出るのは、起動スクリプトの数行だけです。

```bash
# VM 内
kubectl logs -n rustfs -l app=rustfs
```

```
WARNING: RUSTFS_ACCESS_KEY uses the default rustfsadmin credential. Set non-default credentials for production deployments; ...
WARNING: RUSTFS_SECRET_KEY uses the default rustfsadmin credential. Set non-default credentials for production deployments; ...
Initializing data directories: /data
Initializing log directory: /logs
Starting: /usr/bin/rustfs  /data
```

サーバー本体のログは、コンテナの中の `/logs/rustfs.log` に JSON で 1 行ずつ書かれます。

```bash
# VM 内
kubectl exec -n rustfs deploy/rustfs -- rustfs --version
kubectl exec -n rustfs deploy/rustfs -- grep NFS /logs/rustfs.log
```

```
rustfs 1.0.1
build time   : 2026-10-03 03:14:05 +00:00
...
{"timestamp":"2026-10-04T09:30:21.841935498Z","level":"WARN","message":"Unsupported filesystem type detected for RustFS local endpoints: /data (NFS). RustFS only supports direct-attached local POSIX filesystems for production workloads.","env":"RUSTFS_UNSUPPORTED_FS_POLICY","expected":"warn|fail","policy":"warn",...}
```

2 行目の警告は、**`/data` の実体が NFS であることを RustFS が見抜いた**ものです（6 を参照）。

Mac のブラウザで `http://192.168.64.5:30901/rustfs/console/`（VM の IP は `multipass list` で確認）を開くと、RustFS の Web 画面が出ます。
アクセスキー・シークレットキーはどちらも `rustfsadmin` です。`http://192.168.64.5:30901/` だけだと `403` が返ります。

## 4. 2 つの Pod から同時に書き込む

2 つのスクリプトは、どちらも `kubectl run` で aws-cli の Pod を一時的に作り、RustFS に S3 API で頼みます。
接続先は Service の名前 `http://rustfs.rustfs.svc:9000` です。Pod は `default` namespace に作られますが、
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
pod/pod-b created
pod/pod-a created
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
2026-10-04 09:30:47          6 pod-a.txt
2026-10-04 09:30:47          6 pod-b.txt
...
```

2 つとも同じ秒に書かれ、どちらも 6 バイト（ホスト名 `pod-a` と改行）です。
`pod-b` が先に `created` になっているのは、2 つの `kubectl run` を `&` で同時に走らせたためで、順番は実行のたびに変わります。

### SSD の上ではどうなっているか

VM から RustFS のデータディレクトリを見ると、オブジェクトは**ファイルではなくディレクトリ**になっています。

```bash
# VM 内
find /mnt/ssd/rustfs-storage -not -path "*/.rustfs.sys*"
```

```
/mnt/ssd/rustfs-storage
/mnt/ssd/rustfs-storage/test-bucket
/mnt/ssd/rustfs-storage/test-bucket/pod-a.txt
/mnt/ssd/rustfs-storage/test-bucket/pod-a.txt/xl.meta
/mnt/ssd/rustfs-storage/test-bucket/pod-b.txt
/mnt/ssd/rustfs-storage/test-bucket/pod-b.txt/xl.meta
```

`xl.meta` は先頭が `XL2` の独自形式で、小さいオブジェクトは中身もこの中に入ります。
`.rustfs.sys/` には、バケットの設定や利用者の情報など、RustFS 自身の管理データが入ります。
**RustFS のデータディレクトリは RustFS を通して読み書きするもので、直接書き換えるものではありません。**

## 5. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| Pod の `READY 0/1` と `STATUS Running` | コンテナは動いているが、readinessProbe がまだ通っていない。Service の転送先に入っていない |
| `READY 1/1` | readinessProbe が通った。EndpointSlice に Pod の IP が載る |
| PVC が 3 秒で `Bound` | `WaitForFirstConsumer` でも、Deployment がすぐ Pod を作るので待ち時間はほぼない |
| Pod の `Completed` | `kubectl run --restart=Never` の Pod は、コマンドが終われば正常終了になる |
| `aws s3 ls` の日時 | UTC で表示される。日本時間では 9 時間足す |
| `/health/ready` の `"ready":true` | ディスク（`storage`）・利用者の情報（`iam`）・ロックの 3 つが使える状態 |

## 6. 落とし穴

- **RustFS は NFS の上での運用を想定していません。**3 のログのとおり、起動時に `Unsupported filesystem type detected ... (NFS)` を出します。
  既定の扱い（`RUSTFS_UNSUPPORTED_FS_POLICY`）が `warn` なので警告だけで動きますが、本番では VM やノードに直接つながったディスクを使います。
  この教材では、SSD を NFS で VM に見せている（[ssd-nfs.md](../ssd-nfs.md)）ので、学習用と割り切って使っています
- **同時書き込みができるのは、RustFS が 1 つの Pod で受けているからです。**PV の `ReadWriteOnce` は
  「1 つの**ノード**から」という意味で、同じノードなら複数の Pod が同じ PVC をマウントできます。
  実際に、RustFS が動いている間に別の Pod（`busybox:1.37`）から `rustfs-pvc` をマウントでき、`/data/test-bucket` の `pod-a.txt`・`pod-b.txt` が見えました。
  ただしその Pod が `xl.meta` を書き換えれば、RustFS のデータは壊れます
- **`kubectl run` は Pod を作った時点で戻ります。**書き込みの完了を待たずに一覧を取ると、まだ書かれていません。
  `test-concurrent-write.sh` は `kubectl wait` で完了を待ってから一覧を取ります
- **同じ名前のバケットをもう一度作っても、エラーになりません。**バケットができた後に同じ `s3 mb s3://test-bucket` を流すと、
  `make_bucket: test-bucket` と出て Pod は `Completed` になりました。バケットが新しく作られたのか、もとからあったのかは、この出力では区別できません

## 演習

1. `rustfs.yaml` の Service の `selector` を `app: rustfs-typo` に変えて apply し、
   `kubectl get endpointslices -n rustfs` と `curl http://localhost:30900/health/ready` がどう変わるかを見る
2. `readinessProbe` の `path` を `/health/nothing` に変えて apply し、Pod の `READY` がどうなるかを見る
3. `RUSTFS_VOLUMES` を `/nothing` に変えて apply し、Pod がどこにデータを書こうとするか、`/logs/rustfs.log` に何が出るかを見る
4. RustFS が動いている間に `kubectl delete pod -n rustfs -l app=rustfs` で Pod を消し、
   Deployment が別の名前の Pod を作ること、`test-bucket` の中身が残っていることを確かめる

## クリーンアップ

learn4 は、この RustFS をそのまま更新します。**learn4 に進むなら何も消しません。**
ここでやめるときは次のとおりです。

```bash
# VM 内
kubectl delete -f rustfs.yaml       # namespace ごと消える
kubectl delete -f rustfs-pv.yaml
sudo rm -rf /mnt/ssd/rustfs-storage   # バケットとオブジェクトも消す場合
```

## まとめ

- Deployment は ReplicaSet を通して Pod を保ち、Service はラベルで Pod を見つけて転送する
- クラスタ内からは `<Service 名>.<namespace>.svc`、外からは NodePort で届く
- 2 つの Pod の同時書き込みを受け止めているのは、ディスクではなく RustFS の Pod 1 つ
- `ReadWriteOnce` は Pod 単位ではなくノード単位の制限
- 次の [learn4](../learn4/README.md) では、この Deployment に直書きした認証情報を ConfigMap と Secret に移します
