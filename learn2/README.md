# Mac Mini に k3s クラスタを立て、USB SSD をつなぐ

Mac Mini の上に Ubuntu の VM を作り、その中で k3s（軽量な Kubernetes）を動かします。
さらに、Mac に挿した USB SSD を Kubernetes のストレージとして登録し、Pod から書き込みます。

このステップの問いは次のひとつです。

> **Pod が `/data/test.txt` に書いたファイルは、物理的にどこに落ちるのか。**

新しく扱う機構は、クラスタそのもの（ノードとコントロールプレーン）と、ストレージの 3 つのリソース
StorageClass・PersistentVolume（PV）・PersistentVolumeClaim（PVC）です。

## 目次

- [前提条件](#前提条件)
- [1. 全体像: Mac・VM・Pod の 3 層](#1-全体像-macvmpod-の-3-層)
- [2. VM を作る](#2-vm-を作る)
- [3. SSD を VM から見えるようにする](#3-ssd-を-vm-から見えるようにする)
- [4. k3s を入れる](#4-k3s-を入れる)
- [5. ストレージを Kubernetes に登録する](#5-ストレージを-kubernetes-に登録する)
- [6. Pod から書き込む](#6-pod-から書き込む)
- [7. 出力の読み方](#7-出力の読み方)
- [8. 落とし穴](#8-落とし穴)
- [演習](#演習)
- [クリーンアップ](#クリーンアップ)
- [まとめ](#まとめ)

## 前提条件

- Apple Silicon の Mac（この教材では macOS 15.3.1 の Mac Mini）と Homebrew
- USB 接続の外付け SSD。macOS で読み書きできる形式（exFAT、APFS など）でフォーマット済みのもの
- 前のステップの成果は使いません。learn1 のクラスタとは別に、ここで新しく作ります

コマンドの実行場所（Mac 側・VM 内・Pod 内）と、ファイルを VM に持ち込む方法は [vm-setup.md](../vm-setup.md) にまとめてあります。

## 1. 全体像: Mac・VM・Pod の 3 層

このステップで作るものを、SSD 上のファイルから Pod の中のパスまで、下から順に並べます。

```
Pod storage-test の中    /data/test.txt
        │  PVC ssd-pvc → PV ssd-pv（local volume）が Pod の /data にマウントする
VM k3s-master の中       /mnt/ssd/k8s-storage/test.txt
        │  NFS（ネットワーク越しのファイル共有）で Mac の SSD をマウントする
Mac の中                 /Volumes/SSD-PGU3/k8s-storage/test.txt
        │
USB SSD（932 GB）
```

問いの答えを先に書くと、ファイルは **Mac に挿した USB SSD の `k8s-storage/` ディレクトリ**に落ちます。
Pod・VM・Mac の 3 つが、同じファイルを別のパスで見ています。

この環境で実際に使った版は次のとおりです（2026-09-30 に確認）。

| 部品 | 版 |
|---|---|
| macOS | 15.3.1 |
| Multipass | 1.16.1+mac |
| VM の OS | Ubuntu 22.04.5 LTS |
| k3s（Kubernetes） | v1.34.5+k3s1 |
| コンテナランタイム | containerd 2.1.5-k3s1 |

## 2. VM を作る

Kubernetes は Linux の上で動きます。Mac の上に Linux の VM を作るために Multipass を使います。

```bash
# Mac 側
brew install --cask multipass
multipass launch --name k3s-master --cpus 2 --memory 2G --disk 20G 22.04
multipass list
```

```
Name                    State             IPv4             Image
k3s-master              Running           192.168.64.5     Ubuntu 22.04 LTS
```

`192.168.64.5` が VM の IP アドレスです。Mac と VM は `192.168.64.0/24` のネットワークでつながり、
Mac 側は `192.168.64.1` になります（VM の中で `ip route` を見ると `default via 192.168.64.1 dev enp0s1` と出ます）。

メモリ 2GB は、後のステップ（MinIO、Rust のビルド）で足りなくなる大きさです。learn5 でスワップを足して補います。

## 3. SSD を VM から見えるようにする

SSD は Mac に挿さっています。VM から見えるようにするには、Mac を NFS サーバーにして、VM からマウントします。
手順は 4 つで、詳しくは横断解説 [ssd-nfs.md](../ssd-nfs.md) にまとめてあります。

| 手順 | 場所 | すること |
|---|---|---|
| 1 | Mac 側 | `diskutil list external` で SSD のボリューム名を調べる（この教材では `SSD-PGU3`） |
| 2 | Mac 側 | システム設定で `/sbin/nfsd` にフルディスクアクセスを与える |
| 3 | Mac 側 | `/etc/exports` に公開の設定を書き、`sudo nfsd start` と `sudo nfsd update` を実行する |
| 4 | VM 内 | `nfs-common` を入れ、`/mnt/ssd` にマウントする |

終わったら、VM から SSD が見えることを確かめます。

```bash
# VM 内
df -h /mnt/ssd
```

```
Filesystem                      Size  Used Avail Use% Mounted on
192.168.64.1:/Volumes/SSD-PGU3  932G  237G  696G  26% /mnt/ssd
```

`Filesystem` が `192.168.64.1:...` になっていれば、`/mnt/ssd` の中身は Mac の SSD です。
ここが `/dev/sda1` などになっているときは、マウントが外れていて、VM のディスクに書くことになります。

## 4. k3s を入れる

```bash
# VM 内
curl -sfL https://get.k3s.io | sh -
```

このスクリプトは、その時点の最新の安定版を入れます。版を固定したいときは `INSTALL_K3S_VERSION=v1.34.5+k3s1` を付けます。

続けて、`sudo` なしで kubectl を使えるようにします（理由は [vm-setup.md](../vm-setup.md#2-kubectl-と-helm-を-sudo-なしで使う)）。

```bash
# VM 内
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
source ~/.bashrc
kubectl get nodes
```

```
NAME         STATUS   ROLES           AGE    VERSION
k3s-master   Ready    control-plane   186d   v1.34.5+k3s1
```

ノードは 1 台だけです。この 1 台が、クラスタの状態を管理する**コントロールプレーン**と、Pod を実際に動かす**ワーカー**を兼ねます。

### k3s が最初から動かしているもの

何も apply していなくても、`kube-system` namespace にはすでに Pod が動いています。

```bash
# VM 内
kubectl get pods -n kube-system
```

```
NAME                                      READY   STATUS      RESTARTS       AGE
coredns-695cbbfcb9-b5vxb                  1/1     Running     2 (185d ago)   186d
helm-install-traefik-crd-scgnq            0/1     Completed   0              186d
helm-install-traefik-fxr5k                0/1     Completed   1              186d
local-path-provisioner-546dfc6456-x7h9z   1/1     Running     0              186d
metrics-server-c8774f4f4-dc8jl            1/1     Running     1 (185d ago)   186d
svclb-traefik-9243ba81-n9cpr              2/2     Running     0              186d
traefik-788bc4688c-kqgqb                  1/1     Running     1 (185d ago)   186d
```

| Pod | 役割 |
|---|---|
| `coredns` | クラスタ内の名前解決。learn3 の `minio.minio.svc` のような名前を IP に変える |
| `local-path-provisioner` | PVC が来たら、VM のディスク上にディレクトリを作って PV を自動で用意する（この教材では使わない） |
| `metrics-server` | Pod の CPU・メモリ使用量を集める |
| `traefik`、`svclb-traefik` | クラスタの外から HTTP を受ける入口（この教材では使わない） |
| `helm-install-*` | traefik を入れるために 1 回だけ動いた Job。`Completed` は正常終了の意味 |

k3s は「すぐ使える」ように、これらを一緒に入れます。素の Kubernetes では自分で入れる部品です。

### k9s（任意）

k9s はターミナルで動く Kubernetes の画面で、Pod の状態やログを見て回るのに便利です。

```bash
# VM 内
curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_arm64.tar.gz | tar xz
sudo mv k9s /usr/local/bin/
k9s
```

## 5. ストレージを Kubernetes に登録する

まず、このステップのファイルを VM に持ち込み、SSD 上に Kubernetes 用のディレクトリを作ります。

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn2 k3s-master:/home/ubuntu/
```

```bash
# VM 内
sudo mkdir -p /mnt/ssd/k8s-storage
cd /home/ubuntu/learn2
```

ここで作る 3 つのリソースの関係は次のとおりです。

```
StorageClass local-ssd   … 「どういう種類のストレージか」の名前
    ↑ storageClassName で参照
PV ssd-pv                 … 実体: /mnt/ssd/k8s-storage、100Gi
    ↑ バインド（Kubernetes が条件の合う組を結ぶ）
PVC ssd-pvc               … 要求: local-ssd を 10Gi ほしい
    ↑ claimName で参照
Pod storage-test          … /data に PVC をマウントする
```

**PV は管理者が用意する「在庫」、PVC は利用者が出す「注文」**です。Pod は PV を直接指さず、PVC を通して使います。
こうしておくと、Pod のマニフェストに `/mnt/ssd/...` のような VM 固有のパスを書かずに済みます。

### 5-1. StorageClass（`storageclass-ssd.yaml`）

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-ssd
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
```

| フィールド | 値 | なぜこの値か |
|---|---|---|
| `provisioner` | `kubernetes.io/no-provisioner` | NFS 上のディレクトリを PV にする仕組みは k3s に入っていない。PV は手で書く |
| `volumeBindingMode` | `WaitForFirstConsumer` | PVC を、使う Pod が決まるまで PV に結びつけない。local volume はノードに縛られるので、Pod の置き場所と矛盾しないように待つ |

### 5-2. PersistentVolume（`pv-ssd.yaml`）

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ssd-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-ssd
  local:
    path: /mnt/ssd/k8s-storage
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k3s-master
```

| フィールド | 値 | 意味 |
|---|---|---|
| `local.path` | `/mnt/ssd/k8s-storage` | **VM の中の**パス。NFS の先の SSD であることを Kubernetes は知らない |
| `nodeAffinity` | `k3s-master` | このパスがあるノード。local volume では必須 |
| `capacity.storage` | `100Gi` | 申告する容量。**実際の空き容量は調べられず、上限としても効かない** |
| `accessModes` | `ReadWriteOnce` | 1 つの**ノード**から読み書きできる（1 つの Pod ではない。learn3 で確かめる） |
| `persistentVolumeReclaimPolicy` | `Retain` | PVC を消しても PV とファイルを残す |

### 5-3. PersistentVolumeClaim（`pvc-ssd.yaml`）

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ssd-pvc
spec:
  storageClassName: local-ssd
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

### 5-4. apply する

```bash
# VM 内
kubectl apply -f storageclass-ssd.yaml
kubectl apply -f pv-ssd.yaml
kubectl apply -f pvc-ssd.yaml
kubectl get pv,pvc
```

```
NAME                      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   ...
persistentvolume/ssd-pv   100Gi      RWO            Retain           Available           local-ssd      ...

NAME                            STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   ...
persistentvolumeclaim/ssd-pvc   Pending                                      local-ssd      ...
```

PVC が `Pending` なのは異常ではありません。`WaitForFirstConsumer` なので、使う Pod が現れるまで待っています。
`kubectl describe pvc ssd-pvc` の末尾にも、そう書かれています。

```
  Normal  WaitForFirstConsumer  10s   persistentvolume-controller  waiting for first consumer to be created before binding
```

## 6. Pod から書き込む

`test-pod.yaml` は、busybox（小さな Linux のコマンド集）のコンテナに PVC を `/data` としてマウントし、1 時間眠るだけの Pod です。

```bash
# VM 内
kubectl apply -f test-pod.yaml
kubectl wait --for=condition=Ready pod/storage-test --timeout=120s
kubectl get pod storage-test
kubectl get pv,pvc
```

```
NAME           READY   STATUS    RESTARTS   AGE
storage-test   1/1     Running   0          6s

NAME                      CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM             STORAGECLASS   ...
persistentvolume/ssd-pv   100Gi      RWO            Retain           Bound    default/ssd-pvc   local-ssd      ...

NAME                            STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   ...
persistentvolumeclaim/ssd-pvc   Bound    ssd-pv   100Gi      RWO            local-ssd      ...
```

Pod が現れた時点で、PVC が PV に `Bound` になりました。書き込んで、3 つの場所から読みます。

```bash
# VM 内
kubectl exec storage-test -- sh -c "echo hello from k8s \$(date +%F) > /data/test.txt"
kubectl exec storage-test -- cat /data/test.txt   # Pod の中から
cat /mnt/ssd/k8s-storage/test.txt                  # VM から
```

```
hello from k8s 2026-09-30
hello from k8s 2026-09-30
```

Mac の Finder で SSD を開くと、`k8s-storage/test.txt` が見えます。これが問いの答えです。

Pod の中から `/data` の正体を見ると、NFS の先の SSD であることが分かります。

```bash
# VM 内
kubectl exec storage-test -- df -h /data
```

```
Filesystem                Size      Used Available Use% Mounted on
192.168.64.1:/Volumes/SSD-PGU3/k8s-storage
                        931.5G    236.1G    695.5G  25% /data
```

## 7. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| PV の `STATUS` | `Available`（空き在庫）→ `Bound`（PVC と結ばれた）→ `Released`（PVC が消えたが中身が残っている） |
| PVC の `STATUS` | `Pending`（待ち）→ `Bound`。`Pending` の理由は `kubectl describe pvc` の Events に出る |
| PVC の `CAPACITY` | 要求は 10Gi なのに `100Gi` と出る。**PV は丸ごと 1 つの PVC に渡され、分割されない** |
| PV の `CLAIM` | `default/ssd-pvc` のように、どの namespace のどの PVC と結ばれたか |
| Pod の `RESTARTS` | busybox は `sleep 3600` が終わると正常終了し、再起動される。1 時間ごとに 1 増える |

`kubectl get sc` を見ると、`local-ssd` の `RECLAIMPOLICY` は `Delete` と出ます。
これは StorageClass が**自動で作る** PV に付ける既定値で、手で書いた `ssd-pv` には PV 自身の `Retain` が効きます。

```
NAME                   PROVISIONER                    RECLAIMPOLICY   VOLUMEBINDINGMODE      ...
local-path (default)   rancher.io/local-path          Delete          WaitForFirstConsumer   ...
local-ssd              kubernetes.io/no-provisioner   Delete          WaitForFirstConsumer   ...
```

`local-path (default)` は k3s が入れた StorageClass です。PVC で `storageClassName` を省くと、こちらが使われます。

## 8. 落とし穴

- **`Released` の PV は再利用されません。**PVC を消して同じ PVC を作り直しても、PV は `Released` のまま結ばれず、
  Pod は次のイベントで `Pending` のままになります。PV を消して作り直す必要があります（中身のファイルは `Retain` なので残ります）

  ```
  Warning  FailedScheduling  default-scheduler  0/1 nodes are available: 1 node(s) didn't find available persistent volumes to bind. ...
  ```

- **Pod の再起動が積み上がります。**`sleep 3600` の Pod は 1 時間ごとに終了し、再起動されます。
  この教材の環境では、消し忘れた `storage-test` が 186 日で `RESTARTS 4462` になっていました
- **PV の容量は守られません。**`100Gi` と書いても、SSD の空きが 696G あれば 100Gi を超えて書けます
  （⚠ 未検証: 実際に 100Gi を超えて書いてはいません。local volume が容量を制限しないことは仕様による）

## 演習

1. `pvc-ssd.yaml` の `storageClassName` を `local-sdd` に変え、`metadata.name` を `typo-pvc` にして apply する。
   同じ PVC を使う Pod も作り、`kubectl describe pvc typo-pvc` を見る。
   この環境では `storageclass.storage.k8s.io "local-sdd" not found` が出て、Pod も `Pending` のままになりました
2. Pod と PVC を消し（PV は残す）、PVC と Pod を作り直す。PV が `Released` のままで、Pod が `Pending` になることを確かめる
3. `pvc-ssd.yaml` の要求を `200Gi` にして apply し、PV（`100Gi`）と結ばれるかを見る
4. VM の中で `/mnt/ssd/k8s-storage/` にファイルを直接置き、Pod の中の `/data` から見えることを確かめる

## クリーンアップ

learn3 以降は、この StorageClass `local-ssd` と NFS のマウントを使います。**StorageClass とマウントは残します。**
動作確認用の Pod・PVC・PV は消して構いません。

```bash
# VM 内
kubectl delete -f test-pod.yaml
kubectl delete -f pvc-ssd.yaml
kubectl delete -f pv-ssd.yaml
cat /mnt/ssd/k8s-storage/test.txt   # Retain なので、ファイルは残っている
```

VM そのものを止める・消すときは次のとおりです。

```bash
# Mac 側
multipass stop k3s-master    # 止める
multipass start k3s-master   # 起動する
multipass delete --purge k3s-master   # 消す（クラスタもすべて消える）
```

## まとめ

- Pod が `/data` に書いたファイルは、PVC → PV → VM の `/mnt/ssd` → NFS → Mac の USB SSD と渡って保存される
- PV は管理者が用意する在庫、PVC は利用者の注文。Pod は PVC だけを知っている
- `WaitForFirstConsumer` の PVC は、Pod が現れるまで `Pending` で正常
- PV は丸ごと 1 つの PVC に渡され、`Retain` の PV は PVC を消すと `Released` になって再利用されない
- 次の [learn3](../learn3/README.md) では、この StorageClass の上に MinIO（オブジェクトストレージ）を載せます
