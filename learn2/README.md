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

## 7. k9s のインストール

VM 内に k9s (ターミナルベースの Kubernetes UI) をインストールします。

```bash
# VM に入る
multipass shell k3s-master

# 最新バージョンを取得して展開
curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_arm64.tar.gz | tar xz

# バイナリを PATH に移動
sudo mv k9s /usr/local/bin/

# 動作確認
k9s version
```

k3s の場合、kubeconfig のパスを明示的に指定して起動します:

```bash
sudo k9s --kubeconfig /etc/rancher/k3s/k3s.yaml
```

毎回指定するのが面倒な場合は環境変数を設定:

```bash
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
source ~/.bashrc
k9s
```

`sudo` なしで実行したい場合は kubeconfig のパーミッションを変更:

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

---

## 8. SSD を Kubernetes の PersistentVolume として設定

### 8-1. ストレージ用ディレクトリの作成

VM 内で:

```bash
sudo mkdir -p /mnt/ssd/k8s-storage
```

### 8-2. PersistentVolume マニフェストの作成 (`pv-ssd.yaml`)

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

### 8-3. StorageClass の作成 (`storageclass-ssd.yaml`)

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

### 8-4. PersistentVolumeClaim の作成 (`pvc-ssd.yaml`) (動作確認用)

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

## 9. クラスタの動作確認

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

## 10. ストレージへの書き込み確認

テスト用 Pod を立ち上げ、PVC 経由で SSD に実際に書き込めるか確認します。

### 10-1. テスト用 Pod マニフェストの作成

```yaml
# test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
spec:
  containers:
    - name: busybox
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - mountPath: /data
          name: ssd-volume
  volumes:
    - name: ssd-volume
      persistentVolumeClaim:
        claimName: ssd-pvc
```

### 10-2. Pod の起動

```bash
sudo kubectl apply -f test-pod.yaml

# Pod が Running になるまで待つ
sudo kubectl get pod storage-test -w
```

正常な場合の出力例:

```
NAME           READY   STATUS    RESTARTS   AGE
storage-test   1/1     Running   0          30s
```

> **注意**: `WaitForFirstConsumer` モードのため、Pod が起動するタイミングで PVC が PV にバインドされます。PVC の STATUS が `Pending` でも Pod 起動後に `Bound` になります。

### 10-3. 書き込みテスト

```bash
# Pod 内でファイルを書き込む
sudo kubectl exec storage-test -- sh -c "echo 'hello from k8s' > /data/test.txt"

# 書き込んだ内容を確認
sudo kubectl exec storage-test -- cat /data/test.txt
```

期待される出力:

```
hello from k8s
```

### 10-4. VM 側からも確認

```bash
multipass shell k3s-master
cat /mnt/ssd/k8s-storage/test.txt
# hello from k8s
```

### 10-5. テスト用リソースの削除

```bash
sudo kubectl delete pod storage-test
sudo kubectl delete -f test-pod.yaml
```

---

## 11. VM の停止・再起動

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
