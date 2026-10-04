# VM への持ち込みとコマンドの実行場所

learn2 以降のステップで共通する作業をまとめます。各ステップの README はここを参照します。

この教材では、コマンドを実行する場所が 3 つあります。

| 場所 | 何があるか | 入り方 | コードブロックの目印 |
|---|---|---|---|
| Mac | このリポジトリ、Multipass、USB SSD（`/Volumes/<SSD の名前>`） | ターミナルを開く | `# Mac 側` |
| VM `k3s-master` | Ubuntu 22.04、k3s、kubectl、helm、docker | `multipass shell k3s-master` | `# VM 内` |
| Pod の中 | コンテナのファイルシステム | `kubectl exec -it <Pod 名> -- sh` | `# Pod 内` |

## 目次

- [1. ステップのファイルを VM に持ち込む](#1-ステップのファイルを-vm-に持ち込む)
- [2. kubectl と helm を sudo なしで使う](#2-kubectl-と-helm-を-sudo-なしで使う)
- [3. Mac から VM の中のコマンドを 1 つだけ実行する](#3-mac-から-vm-の中のコマンドを-1-つだけ実行する)

## 1. ステップのファイルを VM に持ち込む

マニフェストは Mac 上のこのリポジトリにあり、`kubectl apply` は VM の中で実行します。
そのため、各ステップの最初に `learnN/` を VM にコピーします。

```bash
# Mac 側（リポジトリのルートで実行）
multipass transfer -r learn3 k3s-master:/home/ubuntu/
```

VM の中に `/home/ubuntu/learn3/` ができ、ファイルがそろいます。

**Mac 側でファイルを直したら、もう一度 `transfer` します。**コピーなので自動では反映されません。

**`transfer` は上書きするだけで、Mac 側で消したファイルや名前を変えたファイルは VM に残ります。**
learn3 のマニフェストを `minio*.yaml` から `rustfs*.yaml` に改名して transfer し直した後（2026-10-04）、VM には両方がありました。

```bash
# VM 内
ls /home/ubuntu/learn3
```

```
README.md
create-bucket.sh
minio-pv.yaml
minio.yaml
rustfs-pv.yaml
rustfs.yaml
test-concurrent-write.sh
```

古いファイルを `kubectl apply -f .` のようにまとめて渡すと、それも apply されます。気になるときは VM 側のディレクトリを消してから transfer します。

### `multipass mount` を使わない理由

`multipass mount` は Mac のディレクトリを VM に共有する機能で、動けば `transfer` し直す手間がなくなります。
ただし、この教材の環境（macOS 15.3.1、Multipass 1.16.1）では、次のように**登録はされているのに中身が空**になりました。

```bash
# Mac 側
multipass info k3s-master
# Mounts:         /Users/taku-y/github/taku-y/learn-kubernetes/learn2 => /home/ubuntu/learn2
#                 （他のステップも同様に登録されている）

# VM 内
ls -la /home/ubuntu/learn2
# total 8
# drwxr-xr-x  2 ubuntu ubuntu 4096 Mar 28  2026 .
# drwxr-x--- 18 ubuntu ubuntu 4096 Aug 16 12:26 ..
```

エラーが出ないので気づきにくく、`kubectl apply -f` で初めて `the path "pvc-ssd.yaml" does not exist` と言われます。
確実に動く `transfer` に統一しています。

## 2. kubectl と helm を sudo なしで使う

k3s は、クラスタへの接続情報（kubeconfig）を `/etc/rancher/k3s/k3s.yaml` に書き出します。
kubectl と helm はこのファイルを読んでクラスタに接続します。learn2 の手順で、次の 2 つを済ませてあります。

```bash
# VM 内
sudo chmod 644 /etc/rancher/k3s/k3s.yaml                       # 一般ユーザーにも読めるようにする
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc  # 読む場所を教える
source ~/.bashrc
```

この教材の README は、これを前提に **`sudo` を付けずに** `kubectl` と `helm` を書きます。

`KUBECONFIG` を設定していないと、helm は既定の `localhost:8080` に接続しようとして失敗します。

```
Error: Kubernetes cluster unreachable: Get "http://localhost:8080/version": dial tcp [::1]:8080: connect: connection refused
```

`sudo helm` にしても同じです。root の環境には `KUBECONFIG` がないためです。

> `chmod 644` は、VM にログインできる人なら誰でもクラスタの管理者になれる、という設定です。
> 1 人で使う学習用の VM だから許される設定で、共有するマシンでは使いません。

## 3. Mac から VM の中のコマンドを 1 つだけ実行する

`multipass shell` で入らずに、Mac から 1 つだけ実行することもできます。
このとき `~/.bashrc` は読まれないので、`KUBECONFIG` を明示します。

```bash
# Mac 側
multipass exec k3s-master -- env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A
```
