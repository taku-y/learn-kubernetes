# Mac の USB SSD を NFS で VM に見せる

Mac に挿した USB SSD を、Multipass の VM `k3s-master` から `/mnt/ssd` として読み書きできるようにする手順です。
learn2 で一度だけ行い、learn3 以降の PV（`/mnt/ssd/k8s-storage`、`/mnt/ssd/rustfs-storage` など）はすべてこのマウントの上に作ります。

## 目次

- [1. 何をつなぐのか](#1-何をつなぐのか)
- [2. SSD のマウントポイントを調べる](#2-ssd-のマウントポイントを調べる)
- [3. nfsd にフルディスクアクセスを与える](#3-nfsd-にフルディスクアクセスを与える)
- [4. Mac を NFS サーバーにする](#4-mac-を-nfs-サーバーにする)
- [5. VM からマウントする](#5-vm-からマウントする)
- [6. 再起動後もマウントする](#6-再起動後もマウントする)
- [7. 落とし穴](#7-落とし穴)
- [8. 外すとき](#8-外すとき)

## 1. 何をつなぐのか

```
VM k3s-master（NFS クライアント）   /mnt/ssd
        │  NFS（TCP）、Mac 側のアドレスは 192.168.64.1
Mac（NFS サーバー: nfsd）           /Volumes/SSD-PGU3
        │  USB
USB SSD（932 GB）
```

**NFS** は、ネットワーク越しにディレクトリを共有する仕組みです。
Mac が NFS サーバーになって SSD のディレクトリを公開し、VM がそれを自分のディレクトリにマウントします。

Multipass にも Mac のディレクトリを VM に共有する `multipass mount` がありますが、この教材の環境では中身が空になって使えませんでした
（[vm-setup.md](vm-setup.md#multipass-mount-を使わない理由)）。

この教材の環境での値は次のとおりです（2026-09-30 に確認）。自分の環境の値に読み替えてください。

| 項目 | この教材での値 |
|---|---|
| SSD のボリューム名 | `SSD-PGU3` |
| Mac 上のパス | `/Volumes/SSD-PGU3` |
| VM から見た Mac のアドレス | `192.168.64.1` |
| VM 上のパス | `/mnt/ssd` |

## 2. SSD のマウントポイントを調べる

macOS は外付けドライブを `/Volumes/<ボリューム名>` に見せます。

```bash
# Mac 側
diskutil list external   # 外付けディスクの一覧。SSD の識別子（例: disk4）とボリューム名を確かめる
```

SSD のファイルシステムは、macOS が読み書きできるもの（exFAT、APFS など）なら何でも構いません。
VM が見るのは NFS 越しのファイルで、SSD の形式は VM からは見えないからです。

VM から見た Mac のアドレスは、VM の既定ゲートウェイです。

```bash
# VM 内
ip route | grep default
```

```
default via 192.168.64.1 dev enp0s1 proto dhcp src 192.168.64.5 metric 100
```

## 3. nfsd にフルディスクアクセスを与える

macOS は、外付けドライブへのアクセスをアプリごとに制限しています。NFS サーバーの `nfsd` にも許可が要ります。

1. **システム設定 → プライバシーとセキュリティ → フルディスクアクセス** を開く
2. `+` を押し、`Cmd+Shift+G` で `/sbin/` に移動して `nfsd` を選ぶ

これをしないと、nfsd が外付けドライブを読めず `sandbox_check failed. nfsd has no read access` というエラーになります。

## 4. Mac を NFS サーバーにする

`/etc/exports` に「どのディレクトリを、どのネットワークに公開するか」を 1 行で書きます。この環境で動いている設定は次のとおりです。

```bash
# Mac 側
cat /etc/exports
```

```
/Volumes/SSD-PGU3 -alldirs -maproot=root -network 192.168.64.0 -mask 255.255.255.0
```

| 指定 | 意味 |
|---|---|
| `/Volumes/SSD-PGU3` | 公開するディレクトリ |
| `-alldirs` | その下のどのディレクトリでもマウントしてよい（`/Volumes/SSD-PGU3/k8s-storage` だけをマウントすることもできる） |
| `-maproot=root` | VM の root からのアクセスを、Mac でも root として扱う |
| `-network 192.168.64.0 -mask 255.255.255.0` | VM のネットワーク（`192.168.64.x`）からだけ受け付ける |

書いたら nfsd を起動し、設定を読み込ませます。

```bash
# Mac 側
sudo nfsd start      # nfsd を起動する
sudo nfsd update     # /etc/exports を読み直す
showmount -e localhost
```

`showmount` の一覧に `/Volumes/SSD-PGU3` が出れば、公開できています。

## 5. VM からマウントする

```bash
# VM 内
sudo apt install -y nfs-common    # NFS クライアント
sudo mkdir -p /mnt/ssd
sudo mount -t nfs 192.168.64.1:/Volumes/SSD-PGU3 /mnt/ssd
df -h /mnt/ssd
```

```
Filesystem                      Size  Used Avail Use% Mounted on
192.168.64.1:/Volumes/SSD-PGU3  932G  237G  696G  26% /mnt/ssd
```

`mount` の出力を見ると、NFS の版と通信の方式が分かります。

```bash
# VM 内
mount | grep /mnt/ssd
```

```
192.168.64.1:/Volumes/SSD-PGU3 on /mnt/ssd type nfs (rw,relatime,vers=3,rsize=1048576,wsize=1048576,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,mountaddr=192.168.64.1,mountvers=3,mountport=866,mountproto=tcp,local_lock=none,addr=192.168.64.1)
```

| 項目 | 読み方 |
|---|---|
| `vers=3` | NFS のバージョン 3 |
| `hard` | Mac が応答しなくなると、読み書きはエラーにならずに待ち続ける |
| `proto=tcp` | TCP で通信する |

## 6. 再起動後もマウントする

`mount` コマンドでのマウントは、VM を再起動すると外れます。再起動のたびに自動でマウントするには、`/etc/fstab` に 1 行足します。

```bash
# VM 内
echo "192.168.64.1:/Volumes/SSD-PGU3 /mnt/ssd nfs defaults 0 0" | sudo tee -a /etc/fstab
```

> ⚠ 未検証: この教材の環境の `/etc/fstab` にはこの行が入っておらず、VM も 2026-03-28 から再起動していません。
> 再起動後に自動でマウントされるかは確かめていません。

## 7. 落とし穴

- **マウントが外れても、`/mnt/ssd` は空のディレクトリとして残ります。**その状態で Pod が書き込むと、SSD ではなく VM のディスクに書かれます。
  VM を再起動した後は、`df -h /mnt/ssd` の `Filesystem` が `192.168.64.1:...` になっていることを確かめます
- **Mac がスリープしたり SSD を抜いたりすると、VM の読み書きが止まります。**`hard` マウントなので、エラーにならずに待ち続けます
- **ファイルの持ち主の見え方が、場所によって違います。**同じ `k8s-storage/test.txt` が、VM からは `ubuntu`、Pod の中からは UID `99` の持ち主に見えました。
  ⚠ 未検証: なぜこう見えるのかは調べていません。持ち主に頼る権限の設定（`chmod`・`chown`）は、期待どおりに効かないかもしれません
- **ファイルのロックが使えません。**VM から `/mnt/ssd` のファイルに `lockf`・`flock` をかけると、どちらも `[Errno 37] No locks available` になりました（2026-10-04）。
  マウントは NFS v3（`vers=3`、`local_lock=none`）で、ロックをサーバー（Mac）側に頼む設定です。なぜ通らないのか（Mac 側のロックの仕組みが動いていないのか）は調べていません。
  RustFS は、これが原因で自己修復の途中経過を保存できません（[learn4](learn4/README.md#6-落とし穴)）。
  ⚠ 未検証: マウントに `nolock` を付ければロックが VM の中だけで効くはずですが、試していません
- **SSD は教材専用ではありません。**この教材の SSD には、教材と関係のない個人のファイルも入っています。
  教材の片付けで消すのは `/mnt/ssd/k8s-storage` のような、教材が作ったディレクトリだけにします

## 8. 外すとき

```bash
# VM 内
sudo umount /mnt/ssd
```

`/etc/fstab` に足した行も消します。Mac 側で公開をやめるときは、`/etc/exports` から該当の行を消して `sudo nfsd update` を実行します。
