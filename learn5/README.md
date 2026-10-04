# 自作の Rust プログラムを Job として動かす

`aws-sdk-s3` を使った Rust のプログラムをコンテナイメージにし、Kubernetes の Job として 1 回だけ実行します。
プログラムは RustFS にバケットを作り、ファイルを置いて、一覧を取り、読み戻します。

このステップの問いは次のひとつです。

> **自分でビルドしたイメージを、レジストリを使わずに k3s に渡すには、どうすればよいか。**

新しく扱うリソースは Job です。イメージの置き場所（Docker と containerd）の違いも扱います。

## 目次

- [前提条件](#前提条件)
- [1. イメージの置き場所は 2 つある](#1-イメージの置き場所は-2-つある)
- [2. プログラムの中身](#2-プログラムの中身)
- [3. イメージをビルドする](#3-イメージをビルドする)
- [4. k3s にイメージを取り込む](#4-k3s-にイメージを取り込む)
- [5. Job を実行する](#5-job-を実行する)
- [6. 出力の読み方](#6-出力の読み方)
- [7. 落とし穴](#7-落とし穴)
- [演習](#演習)
- [クリーンアップ](#クリーンアップ)
- [まとめ](#まとめ)

## 前提条件

learn4 を終えて、クリーンアップをしていない状態から始めます。

- namespace `rustfs` で RustFS が動いている
- ConfigMap `rustfs-config`（`access-key`）と Secret `rustfs-secret`（`secret-key`）がある
- バケット `rust-bucket` は、まだ無い

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn5 k3s-master:/home/ubuntu/
```

## 1. イメージの置き場所は 2 つある

VM の中には、コンテナを扱うソフトが 2 つあります。

| ソフト | 入れたもの | 使う人 | イメージの一覧 |
|---|---|---|---|
| Docker Engine | このステップで入れる | `docker build` するあなた | `docker images` |
| containerd | k3s に同梱 | Pod を起動する k3s | `sudo k3s ctr images ls` |

**2 つはイメージの置き場所を共有していません。**`docker build` で作ったイメージは Docker の置き場所に入るだけで、
k3s からは見えません。そこで、Docker からイメージを書き出し（`docker save`）、containerd に読み込ませ（`ctr images import`）ます。

```
Dockerfile ──docker build──→ Docker の置き場所 ──docker save | ctr images import──→ containerd の置き場所 ──→ Pod
```

ふつうはイメージをレジストリ（Docker Hub など）に置き、k3s にそこから取らせます。
このステップではレジストリを使わずに、手で運びます。

## 2. プログラムの中身

`src/main.rs` は次の 4 つを順に行います。

| 操作 | S3 API | 内容 |
|---|---|---|
| バケット作成 | `CreateBucket` | 環境変数 `BUCKET_NAME` のバケットを作る |
| アップロード | `PutObject` | `Hello from Rust on Kubernetes!`（30 バイト）を `hello.txt` として置く |
| 一覧取得 | `ListObjectsV2` | バケットの中身の名前とサイズを出す |
| ダウンロード | `GetObject` | `hello.txt` を読み戻して出す |

接続先と認証情報は環境変数で受け取ります。`job.yaml` が、learn4 の ConfigMap と Secret から渡します。

| 環境変数 | 値の出どころ | 値 |
|---|---|---|
| `S3_ENDPOINT` | `job.yaml` に直書き | `http://rustfs.rustfs.svc:9000` |
| `BUCKET_NAME` | `job.yaml` に直書き | `rust-bucket` |
| `AWS_ACCESS_KEY_ID` | ConfigMap `rustfs-config` の `access-key` | `rustfsadmin` |
| `AWS_SECRET_ACCESS_KEY` | Secret `rustfs-secret` の `secret-key` | `rustfsadmin` |

AWS の SDK を RustFS に向けるために、2 つの設定をしています。

- `endpoint_url` で接続先を RustFS にする。AWS には通信しない
- `force_path_style(true)` で URL を `http://host/bucket/key` の形にする。
  SDK の既定は `http://bucket.host/key` の形で、`rust-bucket.rustfs.rustfs.svc` という名前はクラスタ内で引けない

プログラムは S3 の API しか使っていないので、RustFS に固有のところはありません。
そのため、クレート名（`s3-client`）・イメージ名（`s3-rust-client`）・環境変数名（`S3_ENDPOINT`）に RustFS の名前を入れていません。

## 3. イメージをビルドする

### 3-1. Docker Engine を入れる

```bash
# VM 内
sudo apt-get update
sudo apt-get install -y docker.io docker-buildx
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu   # sudo なしで docker を使えるようにする
exit
```

```bash
# Mac 側（入り直してグループの変更を反映する）
multipass shell k3s-master
```

> Docker Desktop（Mac・Windows の GUI アプリ）は大きな組織での商用利用が有償ですが、
> Linux 上の Docker Engine は Apache 2.0 ライセンスです。

### 3-2. スワップを足す

`aws-sdk-s3` は依存するクレートが多く、コンパイルにメモリを使います。VM のメモリ 2GB では足りないので、2GB のスワップを足します。

```bash
# VM 内
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

```
               total        used        free      shared  buff/cache   available
Mem:           1.9Gi       1.0Gi        55Mi       0.0Ki       904Mi       864Mi
Swap:          2.0Gi       217Mi       1.8Gi
```

### 3-3. ビルドする

Dockerfile は 2 段構成（マルチステージビルド）です。

| 段 | ベースイメージ | すること |
|---|---|---|
| builder | `rust:1.94-slim-bookworm`（約 800MB） | `Cargo.lock` の版で依存クレートをビルドし、次に `src/` をビルドする |
| 実行用 | `debian:bookworm-slim` | ビルドしたバイナリ 1 つと CA 証明書だけを入れる |

コンパイラを含む builder 段は最終イメージに入らないので、できあがりは 123MB です。
2 つの段で Debian の版（bookworm）をそろえているのは、バイナリがリンクする glibc の版を合わせるためです。

```bash
# VM 内
cd /home/ubuntu/learn5
CARGO_BUILD_JOBS=1 docker build -t s3-rust-client:0.1.0 .
docker images s3-rust-client
```

`--progress=plain` を付けて実行したときのログから、2 つの `cargo build` の行を抜き出します。

```
#11 [builder 4/6] RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release
#11 149.0     Finished `release` profile [optimized] target(s) in 2m 28s
#11 DONE 150.5s
...
#13 [builder 6/6] RUN touch src/main.rs && cargo build --release
#13 4.311     Finished `release` profile [optimized] target(s) in 3.91s
#13 DONE 4.4s
```

```
IMAGE                  ID             DISK USAGE   CONTENT SIZE   EXTRA
s3-rust-client:0.1.0   2dfa0bdd4f5d        123MB             0B
```

この環境では全体で 170 秒かかりました。ほとんどは依存クレートのビルド（150 秒）で、自分のコード（`main.rs`）のビルドは 4 秒です。
Dockerfile が依存だけを先にビルドしているので、`main.rs` だけを直したときは、この 150 秒の段がキャッシュから再利用されます。
`CARGO_BUILD_JOBS=1` は並列コンパイルを 1 本に絞り、メモリの使用量を抑えます。

## 4. k3s にイメージを取り込む

```bash
# VM 内
docker save s3-rust-client:0.1.0 | sudo k3s ctr images import -
sudo k3s ctr images ls | grep s3-rust
```

```
docker.io/library/s3-rust-client:0.1.0   ...   120.6 MiB   linux/arm64   ...
```

containerd では、名前に `docker.io/library/` が付きます。Docker Hub の公式イメージと同じ名前の付け方です。

## 5. Job を実行する

**Job** は「Pod を、成功するまで（決まった回数まで）動かす」リソースです。
Deployment が Pod を**動かし続ける**のに対し、Job は Pod が**正常終了したら完了**です。

```yaml
# job.yaml（抜粋）
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: s3-rust-client
          image: s3-rust-client:0.1.0
          imagePullPolicy: Never
```

| 項目 | 値 | 意味 |
|---|---|---|
| `restartPolicy` | `Never` | 失敗した Pod を再起動せず、Job が新しい Pod を作ってやり直す |
| `imagePullPolicy` | `Never` | レジストリから取りに行かず、containerd にあるイメージだけを使う |
| `backoffLimit` | 書いていないので既定の `6` | 失敗は 6 回まで。超えると Job が `Failed` になる |

```bash
# VM 内
kubectl apply -f job.yaml
kubectl wait -n rustfs --for=condition=complete job/s3-rust-client --timeout=120s
kubectl get job,pod -n rustfs -l job-name=s3-rust-client
kubectl logs -n rustfs -l job-name=s3-rust-client
```

```
NAME                       STATUS     COMPLETIONS   DURATION   AGE
job.batch/s3-rust-client   Complete   1/1           4s         5s

NAME                       READY   STATUS      RESTARTS   AGE
pod/s3-rust-client-wvl8t   0/1     Completed   0          4s
```

```
バケットを作成中: rust-bucket
完了
アップロード中: hello.txt
完了
オブジェクト一覧:
  - hello.txt (30 bytes)
ダウンロード中: hello.txt
内容: Hello from Rust on Kubernetes!
```

RustFS のデータディレクトリにも `rust-bucket/hello.txt` ができています。

```bash
# VM 内
find /mnt/ssd/rustfs-storage -maxdepth 2 -not -path "*/.rustfs.sys*"
```

```
/mnt/ssd/rustfs-storage
/mnt/ssd/rustfs-storage/rust-bucket
/mnt/ssd/rustfs-storage/rust-bucket/hello.txt
/mnt/ssd/rustfs-storage/test-bucket
/mnt/ssd/rustfs-storage/test-bucket/pod-a.txt
/mnt/ssd/rustfs-storage/test-bucket/pod-b.txt
```

## 6. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| Job の `COMPLETIONS 1/1` | 成功した Pod の数 / 必要な数 |
| Job の `DURATION 4s` | 最初の Pod の起動から完了まで |
| Pod の `Completed` | コンテナが終了コード 0 で終わった。Pod は消えずに残り、ログを読める |
| Pod の `Error` | コンテナが 0 以外で終わった。Job は `backoffLimit` まで別の Pod を作ってやり直す |

## 7. 落とし穴

- **同じ Job を 2 回目に流しても成功します。サーバーによっては失敗します。**プログラムは最初に必ずバケットを作ります。
  RustFS は、既にあるバケットの作成にも成功を返すので、2 回目も `Complete` になり、ログは 1 回目と同じでした。
  MinIO を使っていたころは、2 回目が `BucketAlreadyOwnedByYou`（HTTP 409）で失敗し、Job が `backoffLimit` までやり直していました。
  **同じプログラムでも、S3 互換サーバーごとに細かい返し方が違います。**
  なお、Job は同じ名前で apply し直せないので、2 回目の前に `kubectl delete -f job.yaml` をします
- **取り込んでいないタグを指定すると、Pod は起動しません。**`imagePullPolicy: Never` なので取りに行きもせず、`ErrImageNeverPull` になります

  ```
  Warning  ErrImageNeverPull  5s (x2 over 6s)  kubelet  Container image "s3-rust-client:0.2.0" is not present with pull policy of Never
  ```

- **使われていないイメージは、ディスクが埋まると k3s に消されます。**kubelet はディスクの使用率が 85% を超えると、
  どの Pod も使っていないイメージを消します。この環境では、ビルドで Docker のキャッシュが 2GB 増えたときに、
  使っていなかった `minio/minio:latest` などが消えました（2026-09-30、MinIO を使っていたころ。k3s のログに `Removing image to free bytes` が出る）。
  ビルドの後は `docker builder prune -af` でキャッシュを消しておきます
- **タグに `latest` を使うと、`imagePullPolicy` の既定が `Always` になります。**`latest` のイメージを取り込んで使うときは、`imagePullPolicy: Never` か `IfNotPresent` を明示します

## 演習

1. `job.yaml` の `BUCKET_NAME` を `Rust_Bucket` （S3 のバケット名に使えない大文字と `_`）に変えて、Job を消してから apply し直す。Pod のログと `STATUS` を見る
2. `job.yaml` の `image` を `s3-rust-client:0.2.0` に変えて apply し、`kubectl describe pod` で `ErrImageNeverPull` を確かめる
3. `src/main.rs` の文言を変えて `0.2.0` としてビルドし、取り込み、演習 2 の Job が動くようにする。
   `main.rs` だけの変更で、依存クレートのビルドがキャッシュされることを確かめる
4. Secret `rustfs-secret` の `secret-key` を間違った値にして Job を流し、ログに何が出るかを見る（終わったら元に戻す）

## クリーンアップ

learn6 では、learn3〜learn5 の RustFS を消して Helm で入れ直します。Job は消しておきます。

```bash
# VM 内
kubectl delete -f job.yaml
docker builder prune -af   # ビルドのキャッシュ（約 2GB）を消す
```

## まとめ

- Docker と k3s（containerd）はイメージの置き場所が別。`docker save | k3s ctr images import` で運ぶ
- Job は Pod を正常終了させるためのリソース。失敗すると `backoffLimit` まで別の Pod でやり直す
- `imagePullPolicy: Never` は、取り込んだイメージだけを使う指定。無ければ `ErrImageNeverPull`
- 使っていないイメージは、ディスクが埋まると消される
- 次の [learn6](../learn6/README.md) では、learn3〜learn5 で手書きした RustFS を Helm の Chart で置き換えます
