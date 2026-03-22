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

## 4. USB SSD を VM にマウント

### 4-1. Mac 側で SSD のマウントポイントを確認

```bash
diskutil info /dev/disk4 | grep "Mount Point"
# 例: Mount Point: /Volumes/SSD
```

### 4-2. Multipass でホストディレクトリをマウント

```bash
multipass mount /Volumes/SSD k3s-master:/mnt/ssd
```

マウント確認:

```bash
multipass info k3s-master
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
sudo kubectl get nodes
```

---

## 7. SSD を Kubernetes の PersistentVolume として設定

### 7-1. ストレージ用ディレクトリの作成

VM 内で:

```bash
sudo mkdir -p /mnt/ssd/k8s-storage
```

### 7-2. PersistentVolume マニフェストの作成

VM 内、または Mac のエディタで以下のファイルを作成します。

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

### 7-3. StorageClass の作成

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

### 7-4. PersistentVolumeClaim の作成 (動作確認用)

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

# Mac 側でマウント確認
multipass info k3s-master
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
