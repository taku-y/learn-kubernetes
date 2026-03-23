# Mac Mini に Kubernetes コントロールプレーンを構築する

Multipass と k3s を使用して、Mac Mini 上に Kubernetes コントロールプレーンを立ち上げる手順です。
USB 接続した SSD を Kubernetes から利用可能なストレージとして設定します。

---

## 前提条件

- Mac Mini (macOS Ventura 以降推奨)
- USB 接続の外付け SSD (フォーマット済み、またはこれからフォーマットする)
- Homebrew がインストール済み
- インターネット接続

---

## 1. Multipass のインストール

```bash
brew install --cask multipass
```

インストール確認:

```bash
multipass version
```

---

## 2. USB SSD の準備

### 2-1. SSD を Mac に接続・確認

```bash
diskutil list
```

接続した SSD のディスク識別子を確認します (例: `/dev/disk4`)。

### 2-2. SSD のフォーマットについて

`multipass mount` はブロックデバイスのパススルーではなく、**ホストのディレクトリを VM に共有フォルダとしてマウント**する仕組みです。
そのため、**SSD のファイルシステムは ext4 である必要はありません**。macOS が読み書きできる形式であれば何でも使用できます。

| フォーマット | 可否 | 備考 |
|---|---|---|
| exFAT | ○ | Mac との相性が良くおすすめ |
| APFS | ○ | Mac 標準フォーマット |
| HFS+ | ○ | 問題なし |
| ext4 | △ | macOS は標準で読み書き不可のため逆に不便 |

Kubernetes (k3s) 側は VM 内のパス (`/mnt/ssd/k8s-storage`) を利用するだけなので、SSD 自体のフォーマットは影響しません。

既存データが不要な場合は exFAT でフォーマットします:

```bash
diskutil eraseDisk ExFAT SSD disk4
```

> **注意**: `disk4` は実際のディスク識別子に置き換えてください。データは消去されます。

### 2-3. マウントポイントの確認

**マウントポイント**とは、SSD に「どのフォルダ名でアクセスできるか」を示すパスです。
macOS は外付けドライブを接続すると、自動的に `/Volumes/ドライブ名` というフォルダとして認識します。
たとえば「SSD」という名前でフォーマットした場合、`/Volumes/SSD` がマウントポイントになります。

以下のコマンドでマウントポイントを確認します:

```bash
diskutil info /dev/disk4 | grep "Mount Point"
# 出力例: Mount Point: /Volumes/SSD
```

このパスは、次のステップで Multipass に SSD を渡す際に使用します。

---

## 3. Multipass VM の作成

コントロールプレーン用の VM を作成します。

```bash
multipass launch --name k3s-master \
  --cpus 2 \
  --memory 2G \
  --disk 20G \
  22.04
```

VM の起動確認:

```bash
multipass list
```

---

## 4. USB SSD を VM にマウント (NFS 方式)

macOS Sequoia + Multipass (qemu driver) 環境では `multipass mount` が正常に動作しないため、NFS を使って SSD を VM に共有します。

### 4-1. Mac 側で SSD のマウントポイントを確認

パーティション一覧を確認:

```bash
diskutil list /dev/disk4
```

パーティション (例: `disk4s2`) のマウントポイントを確認:

```bash
diskutil info /dev/disk4s2 | grep "Mount Point"
# 例: Mount Point: /Volumes/SSD
```

### 4-2. macOS のフルディスクアクセスを許可

`nfsd` が外付けドライブにアクセスするには**フルディスクアクセス**の権限が必要です。

1. **システム設定** → **プライバシーとセキュリティ** → **フルディスクアクセス** を開く
2. 鍵アイコンをクリックしてロック解除
3. `+` ボタンを押し、`Cmd+Shift+G` で `/sbin/` に移動
4. `nfsd` を選択して追加

> **注意**: この設定を行わないと `sandbox_check failed. nfsd has no read access` エラーが発生します。

### 4-3. Mac 側で NFS サーバーを設定

`/etc/exports` に SSD のパスとアクセス許可するサブネットを追加:

```bash
sudo sh -c 'echo "/Volumes/SSD 192.168.64.0 -network 255.255.255.0 -alldirs -mapall=$(id -u):$(id -g)" >> /etc/exports'
```

NFS サーバーを起動:

```bash
sudo nfsd start
sudo nfsd update
```

設定確認:

```bash
showmount -e localhost
# /Volumes/SSD が表示されれば OK
```

### 4-4. VM から見た Mac の IP アドレスを確認

```bash
multipass shell k3s-master
ip route | grep default
# 例: default via 192.168.64.1 dev enth0
# → Mac の IP は 192.168.64.1
```

### 4-5. VM 内で NFS クライアントをインストールしてマウント

```bash
# VM 内で実行
sudo apt install -y nfs-common
sudo mkdir -p /mnt/ssd
sudo mount -t nfs 192.168.64.1:/Volumes/SSD /mnt/ssd
```

マウント確認:

```bash
df -h /mnt/ssd
ls /mnt/ssd
```

### 4-6. VM 再起動時に自動マウントする設定

`/etc/fstab` に追記して永続化:

```bash
echo "192.168.64.1:/Volumes/SSD /mnt/ssd nfs defaults 0 0" | sudo tee -a /etc/fstab
```

---

## 5. VM 内での SSD 設定

VM にログイン:

```bash
multipass shell k3s-master
```

マウント確認:

```bash
ls /mnt/ssd
df -h /mnt/ssd
```

---

## 6. k3s のインストール (コントロールプレーン)

VM 内で k3s をインストールします。

```bash
curl -sfL https://get.k3s.io | sh -
```

インストール後、k3s の起動を確認:

```bash
sudo systemctl status k3s
```

正常な場合の出力例:

```
● k3s.service - Lightweight Kubernetes
     Loaded: loaded (/etc/systemd/system/k3s.service; enabled; vendor preset: enabled)
     Active: active (running) since ...
```

```bash
sudo kubectl get nodes
```

正常な場合の出力例:

```
NAME         STATUS   ROLES                  AGE   VERSION
k3s-master   Ready    control-plane,master   1m    v1.x.x+k3s1
```

`STATUS` が `Ready` になっていれば正常です。

---

## 7. SSD を Kubernetes の PersistentVolume として設定

### 7-1. ストレージ用ディレクトリの作成

VM 内で:

```bash
sudo mkdir -p /mnt/ssd/k8s-storage
```

### 7-2. PersistentVolume マニフェストの作成 (`pv-ssd.yaml`)

**PersistentVolume (PV)** は、クラスタ内で使用できるストレージの実体を定義するリソースです。SSD 上の物理的なディレクトリを Kubernetes のストレージとして登録します。

| フィールド | 値 | 説明 |
|---|---|---|
| `capacity.storage` | `100Gi` | 提供するストレージ容量 |
| `accessModes` | `ReadWriteOnce` | 単一ノードからの読み書きを許可 |
| `persistentVolumeReclaimPolicy` | `Retain` | PVC 削除後もデータを保持する |
| `storageClassName` | `local-ssd` | 対応する StorageClass 名 |
| `local.path` | `/mnt/ssd/k8s-storage` | VM 内のストレージパス |
| `nodeAffinity` | `k3s-master` | このノードにのみバインドする |

```yaml
# pv-ssd.yaml
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

適用:

```bash
sudo kubectl apply -f pv-ssd.yaml
```

### 7-3. StorageClass の作成 (`storageclass-ssd.yaml`)

**StorageClass** は、ストレージの種類と動作を定義するリソースです。PVC がどの PV にバインドされるかをこの名前 (`local-ssd`) で紐付けます。

| フィールド | 値 | 説明 |
|---|---|---|
| `provisioner` | `kubernetes.io/no-provisioner` | 動的プロビジョニングを行わず手動で PV を管理する |
| `volumeBindingMode` | `WaitForFirstConsumer` | Pod がスケジュールされるまでバインドを遅延させる |

```yaml
# storageclass-ssd.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-ssd
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
```

適用:

```bash
sudo kubectl apply -f storageclass-ssd.yaml
```

### 7-4. PersistentVolumeClaim の作成 (`pvc-ssd.yaml`) (動作確認用)

**PersistentVolumeClaim (PVC)** は、Pod がストレージを要求するためのリソースです。`storageClassName` が一致する PV に自動的にバインドされます。

| フィールド | 値 | 説明 |
|---|---|---|
| `storageClassName` | `local-ssd` | 使用する StorageClass 名 |
| `accessModes` | `ReadWriteOnce` | 単一ノードからの読み書きを要求 |
| `resources.requests.storage` | `10Gi` | 要求するストレージ容量 |

```yaml
# pvc-ssd.yaml
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

適用:

```bash
sudo kubectl apply -f pvc-ssd.yaml
sudo kubectl get pvc
```

---

## 8. クラスタの動作確認

```bash
# ノード確認
sudo kubectl get nodes -o wide

# PersistentVolume 確認
sudo kubectl get pv

# PersistentVolumeClaim 確認
sudo kubectl get pvc

# 全リソース確認
sudo kubectl get all -A
```

---

## 9. kubeconfig の取得 (Mac 側から操作する場合)

VM の kubeconfig を Mac にコピーして、Mac から `kubectl` を使えるようにします。

### 9-1. Mac に kubectl をインストール

```bash
brew install kubectl
```

### 9-2. kubeconfig をコピー

```bash
# VM の IP アドレスを確認
multipass info k3s-master | grep IPv4

# kubeconfig を取得
multipass exec k3s-master -- sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config-k3s
```

### 9-3. サーバーアドレスを VM の IP に変更

`~/.kube/config-k3s` 内の `server: https://127.0.0.1:6443` を VM の実際の IP に置き換えます。

```bash
# 例: VM の IP が 192.168.64.10 の場合
sed -i '' 's/127.0.0.1/192.168.64.10/' ~/.kube/config-k3s
```

### 9-4. kubeconfig を設定

```bash
export KUBECONFIG=~/.kube/config-k3s

# または既存の config とマージ
export KUBECONFIG=~/.kube/config:~/.kube/config-k3s
kubectl config view --flatten > ~/.kube/config-merged
mv ~/.kube/config-merged ~/.kube/config
```

### 9-5. Mac から動作確認

```bash
kubectl get nodes
kubectl get pv
```

---

## トラブルシューティング

### k3s が起動しない

```bash
sudo journalctl -u k3s -f
```

### SSD がマウントされない

```bash
# VM 内でマウント状況確認
mount | grep ssd

# NFS サーバーの状態確認 (Mac 側)
sudo nfsd status
showmount -e localhost

# NFS サーバーの再起動 (Mac 側)
sudo nfsd stop
sudo nfsd start
sudo nfsd update
```

### kubectl が "connection refused" になる

VM の IP アドレスが変わっている可能性があります。再確認して kubeconfig を更新してください。

```bash
multipass info k3s-master | grep IPv4
```

---

## VM の停止・再起動

```bash
# 停止
multipass stop k3s-master

# 再起動
multipass start k3s-master

# 削除 (不要になった場合)
multipass delete k3s-master
multipass purge
```

> **注意**: VM を再起動すると IP アドレスが変わる場合があります。その際は kubeconfig のサーバーアドレスを再設定してください。
