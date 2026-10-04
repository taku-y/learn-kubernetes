# 用語集

この教材に出てくる用語を、分野ごとにまとめます。どのステップにも属さない横断の解説です。
各用語には、この教材での実例（リソース名や値）と、最初に出てくるステップを添えました。

learn1〜learn6 の README とマニフェストから、2026-09-30 に遡ってまとめました。
新しいステップで新しい用語を使ったら、ここに書き足します。

## 目次

- [1. クラスタと実行環境](#1-クラスタと実行環境)
- [2. ワークロード](#2-ワークロード)
- [3. 設定と認証情報](#3-設定と認証情報)
- [4. ネットワーク](#4-ネットワーク)
- [5. ストレージ](#5-ストレージ)
- [6. コンテナイメージ](#6-コンテナイメージ)
- [7. Helm](#7-helm)
- [8. MinIO と S3](#8-minio-と-s3)
- [9. 操作の道具](#9-操作の道具)

## 1. クラスタと実行環境

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| Kubernetes | コンテナを複数のマシンに配置し、望んだ状態を保ち続けるための仕組み | この教材の主題 | [learn1](learn1/README.md) |
| クラスタ | Kubernetes が管理するマシン（ノード）の集まり | Mac Mini 上の VM 1 台だけのクラスタ | [learn2](learn2/README.md) |
| ノード（Node） | クラスタに参加している 1 台のマシン。Pod はノードの上で動く | `k3s-master` | [learn2](learn2/README.md) |
| コントロールプレーン | クラスタ全体の状態を持ち、Pod をどのノードに置くかを決める部分 | `k3s-master` がコントロールプレーンとワーカーを兼ねる | [learn2](learn2/README.md) |
| k3s | 軽量な Kubernetes のディストリビューション。1 つのバイナリで動く | `curl -sfL https://get.k3s.io \| sh -` で入れる | [learn2](learn2/README.md) |
| Multipass | Mac などの上に Ubuntu の VM を手早く作る道具 | `multipass launch --name k3s-master` | [learn2](learn2/README.md) |
| etcd | クラスタの状態（リソースの定義）を保存するデータベース。Kubernetes の標準 | この教材の k3s は使っていない（`etcd datastore disabled`） | [learn4](learn4/README.md) |
| SQLite（kine） | ノード 1 台の k3s が etcd の代わりに使うデータベース。1 つのファイル | `/var/lib/rancher/k3s/server/db/state.db`。Secret が平文で入っている | [learn4](learn4/README.md) |
| マニフェスト | リソースの望む状態を書いた YAML ファイル。`kubectl apply -f` で渡す | `myapp.yaml`、`minio.yaml` | [learn1](learn1/README.md) |
| リソース | Kubernetes が管理する対象の 1 つ 1 つ（Pod、Service、PV など）。`kind` で種類を表す | `kind: Deployment` | [learn1](learn1/README.md) |
| Namespace | リソースを名前で区切るための入れ物。指定しなければ `default` に入る | `minio` | [learn3](learn3/README.md) |

## 2. ワークロード

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| Pod | 1 つ以上のコンテナをまとめて動かす最小単位 | `storage-test`、`pod-a`、`pod-b` | [learn1](learn1/README.md) |
| Deployment | 指定した数の Pod を動かし続けるリソース。Pod が消えると作り直す | `myapp`（`replicas: 1`）、`minio` | [learn1](learn1/README.md) |
| ReplicaSet | 「この形の Pod を N 個保つ」リソース。Deployment が作り、Pod のひな形が変わると新しいものを作る | Pod 名 `minio-7945684899-hbmpf` の真ん中が ReplicaSet の識別子 | [learn3](learn3/README.md) |
| レプリカ（replicas） | Deployment が保つ Pod の数 | `replicas: 1` | [learn1](learn1/README.md) |
| Job | 1 回で終わる処理を実行するリソース。完了した Pod は `Completed` になる | `minio-rust-client` | [learn5](learn5/README.md) |
| `backoffLimit` | Job が失敗した Pod をやり直す回数の上限。既定は 6 | 2 回目の Job は `BucketAlreadyOwnedByYou` で失敗を繰り返す | [learn5](learn5/README.md) |
| `restartPolicy` | コンテナが終わったときに再起動するか。Job では `Never` か `OnFailure` | `restartPolicy: Never` | [learn5](learn5/README.md) |
| ラベル / セレクタ | リソースに付ける `key: value` と、それで対象を選ぶ条件 | `app: myapp`、`-l job-name=minio-rust-client` | [learn1](learn1/README.md) |
| readinessProbe | コンテナが応答できるかを定期的に確かめる設定。通るまで `READY 0/1` で、Service の転送先に入らない | `/minio/health/ready` を 5 秒ごと | [learn3](learn3/README.md) |
| requests / limits | コンテナが確保するリソース量（requests）と上限（limits）。requests の合計がノードに収まらないと Pod は置かれない | `requests.memory: 16Gi` で `Insufficient memory` | [learn6](learn6/README.md) |
| ロールアウト | Deployment が Pod を新しいひな形のものに入れ替えること。`kubectl rollout restart` で、ひな形を変えずに入れ替えもできる | Secret を変えた後の `rollout restart` | [learn4](learn4/README.md) |
| `Running` / `Completed` / `Pending` | Pod や PVC の状態の表示。`Pending` は待ち | Pod の `Running`、Job の Pod の `Completed`、PVC の `Pending` | [learn2](learn2/README.md) |

## 3. 設定と認証情報

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| ConfigMap | 機密でない設定値を Key-Value で持つリソース。環境変数やファイルとして Pod に渡す | `myapp-config`（nginx のテンプレート）、`minio-config`（`root-user`） | [learn1](learn1/README.md) |
| Secret | 機密の値を持つリソース。値は base64 で保存されるが、暗号化ではない | `myapp-secret`（`MY_ENV`）、`minio-secret`（`root-password`） | [learn1](learn1/README.md) |
| base64 | バイト列を英数字と記号の文字列で表す符号化。誰でも元に戻せる | `a3ViZXJuZXRlcw==` → `kubernetes` | [learn1](learn1/README.md) |
| `last-applied-configuration` | `kubectl apply` が前回の内容を保存する注釈。`stringData` の値も平文で入る | `{"stringData":{"root-password":"minioadmin"}}` | [learn4](learn4/README.md) |
| `stringData` | Secret に平文で値を書くためのフィールド。保存時に base64 に変換される | `stringData.root-password: minioadmin` | [learn4](learn4/README.md) |
| `configMapKeyRef` / `secretKeyRef` | 環境変数の値を ConfigMap / Secret の特定のキーから取る書き方 | `MINIO_ROOT_PASSWORD` を `minio-secret` の `root-password` から取る | [learn1](learn1/README.md) |
| envsubst | テキスト中の `$VAR` を環境変数の値で置き換えるコマンド。公式 nginx イメージが起動時に使う | `Hello $MY_ENV` → `Hello kubernetes` | [learn1](learn1/README.md) |
| RBAC | 誰がどのリソースに何をしてよいかを決める仕組み。Secret はこれで守る | 名前だけ出てくる | [learn4](learn4/README.md) |

## 4. ネットワーク

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| Service | Pod の集まりに一定の名前とアドレスでアクセスさせるリソース | `minio` | [learn3](learn3/README.md) |
| NodePort | Service の種類のひとつ。ノードの決まったポートでクラスタの外から受ける | API は `30900`、Console は `30901` | [learn3](learn3/README.md) |
| EndpointSlice | Service の転送先（Pod の IP とポート）の一覧。ラベルで見つけた Pod が入る | `minio-stk7d` に `10.42.0.110` | [learn3](learn3/README.md) |
| クラスタ内 DNS 名 | Service に `<Service 名>.<Namespace>.svc` で届く名前 | `http://minio.minio.svc:9000` | [learn3](learn3/README.md) |
| port-forward | 手元のポートを Pod のポートにつなぐ `kubectl` の機能。Service がなくても試せる | `kubectl port-forward deployment/myapp 8080:80` | [learn1](learn1/README.md) |

## 5. ストレージ

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| PersistentVolume（PV） | クラスタで使えるストレージの実体を登録するリソース | `ssd-pv`（`/mnt/ssd/k8s-storage`）、`minio-pv`、`minio-helm-pv` | [learn2](learn2/README.md) |
| PersistentVolumeClaim（PVC） | Pod がストレージを要求するリソース。条件の合う PV に結びつく（バインド） | `ssd-pvc`（10Gi） | [learn2](learn2/README.md) |
| StorageClass | ストレージの種類と振る舞いを定義するリソース。PV・PVC は `storageClassName` で参照する | `local-ssd` | [learn2](learn2/README.md) |
| バインド | PVC が特定の PV に結びつくこと。`kubectl get pvc` の `Bound` | `ssd-pvc` → `ssd-pv` | [learn2](learn2/README.md) |
| `kubernetes.io/no-provisioner` | 動的に PV を作らない、という指定。PV は手で作る | `local-ssd` の `provisioner` | [learn2](learn2/README.md) |
| `WaitForFirstConsumer` | Pod が配置されるまで PVC のバインドを待つ指定。それまで PVC は `Pending` | `local-ssd` の `volumeBindingMode` | [learn2](learn2/README.md) |
| local volume | ノード上のディレクトリをそのまま PV にする方式。`nodeAffinity` でノードを固定する | `local.path: /mnt/ssd/k8s-storage` | [learn2](learn2/README.md) |
| `nodeAffinity` | リソースを置いてよいノードの条件 | `kubernetes.io/hostname In [k3s-master]` | [learn2](learn2/README.md) |
| `ReadWriteOnce` | 1 つのノードからだけ読み書きできるアクセスモード | 教材の PV・PVC はすべてこれ | [learn2](learn2/README.md) |
| `Retain` | PVC を消しても PV とデータを残す回収方針 | `persistentVolumeReclaimPolicy: Retain` | [learn2](learn2/README.md) |
| `Released` | PVC が消えた後の `Retain` の PV の状態。新しい PVC とは結ばれない | `ssd-pv` を作り直すまで Pod が `Pending` | [learn2](learn2/README.md) |
| `claimRef` | PV に記録される「この PV はどの PVC のものか」という予約。`Released` の PV にも残り、外すと `Available` に戻る | `kubectl patch pv minio-helm-pv -p '{"spec":{"claimRef": null}}'` | [learn6](learn6/README.md) |
| finalizer | 条件が満たされるまでリソースの削除を止める印。PV には `kubernetes.io/pv-protection` が付く | 使用中の `minio-pv` を消すと `Terminating` のまま残る | [learn4](learn4/README.md) |
| NFS | ネットワーク越しにディレクトリを共有する仕組み | Mac の `/Volumes/SSD` を VM の `/mnt/ssd` にマウントする | [learn2](learn2/README.md) |
| マウントポイント | ディスクや共有ディレクトリが見えるパス | Mac 側 `/Volumes/SSD`、VM 側 `/mnt/ssd` | [learn2](learn2/README.md) |

## 6. コンテナイメージ

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| コンテナイメージ | コンテナの中身（ファイルと起動コマンド）をまとめたもの。`名前:タグ` で指す | `docker.io/nginx:1.23`、`minio/minio:latest` | [learn1](learn1/README.md) |
| タグ | イメージの版を表す名前。`latest` は固定された版ではない | `1.23`、`latest` | [learn1](learn1/README.md) |
| containerd | k3s が使うコンテナの実行環境。Docker とはイメージの置き場所が別 | `sudo k3s ctr images import -` で取り込む | [learn5](learn5/README.md) |
| Docker Engine | Linux 上でイメージをビルド・実行する道具 | VM 内で `docker build` に使う | [learn5](learn5/README.md) |
| マルチステージビルド | ビルド用と実行用でベースイメージを分ける Dockerfile の書き方 | `rust:slim` でビルドし、`debian:bookworm-slim` で動かす | [learn5](learn5/README.md) |
| `imagePullPolicy: Never` | レジストリから取りに行かず、ノードにあるイメージだけを使う指定。無ければ `ErrImageNeverPull` | `minio-rust-client:0.1.0` | [learn5](learn5/README.md) |
| イメージ GC | ディスクの使用率が 85% を超えると、kubelet が使われていないイメージを消す仕組み | ビルド中に `minio/minio:latest` が消えた | [learn5](learn5/README.md) |
| スワップ | メモリが足りないときにディスクを代わりに使う領域 | Rust のビルド用に 2GB の `/swapfile` を足す | [learn5](learn5/README.md) |

## 7. Helm

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| Helm | Kubernetes のパッケージマネージャー。マニフェストのテンプレートに値を入れて展開する | `helm install minio minio-official/minio` | [learn6](learn6/README.md) |
| Chart | 複数のマニフェストのテンプレートをまとめたパッケージ | `minio-official/minio` | [learn6](learn6/README.md) |
| Values | Chart に渡す設定値。`values.yaml` で書き、テンプレートの既定値を上書きする | `learn6/values.yaml`、`learn6/values-v2.yaml` | [learn6](learn6/README.md) |
| Release | Chart をある設定でインストールした実体。名前で管理する | `minio` | [learn6](learn6/README.md) |
| Revision | Release の版の番号。`upgrade` と `rollback` のたびに 1 増える。記録は Secret `sh.helm.release.v1.<Release>.v<N>` に入る | install で 1、upgrade で 2、rollback で 3 | [learn6](learn6/README.md) |
| hook | install・upgrade の前後に Chart が動かす Job など | MinIO の Chart の `minio-post-job`（`post-install,post-upgrade`） | [learn6](learn6/README.md) |
| Chart リポジトリ | Chart を配布する場所 | `https://charts.min.io/`（`minio-official`） | [learn6](learn6/README.md) |
| Bitnami | 多くの Chart とイメージを配布していた提供元。2025 年に無料の範囲を制限した | learn6 で公式 MinIO Chart に切り替えた理由 | [learn6](learn6/README.md) |
| ServiceAccount | Pod が API を呼ぶときの身元 | Chart が作る `minio-sa` | [learn6](learn6/README.md) |

## 8. MinIO と S3

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| MinIO | S3 互換の API を持つオブジェクトストレージ。2025 年 10 月に無償のイメージの配布が終わった | `minio` namespace の Deployment | [learn3](learn3/README.md) |
| `xl.meta` | MinIO がオブジェクトごとに作るファイル。小さいオブジェクトは中身もここに入る | `test-bucket/pod-a.txt/xl.meta` | [learn3](learn3/README.md) |
| オブジェクトストレージ | ファイルを「バケット」と「キー」で読み書きするストレージ。ディレクトリの階層は持たない | `s3://test-bucket/pod-a.txt` | [learn3](learn3/README.md) |
| S3 互換 API | Amazon S3 と同じ呼び方で使える API。S3 用の道具（aws-cli、aws-sdk）がそのまま使える | `aws s3 cp --endpoint-url http://minio.minio.svc:9000` | [learn3](learn3/README.md) |
| バケット | オブジェクトを入れる入れ物 | `test-bucket`、`rust-bucket` | [learn3](learn3/README.md) |
| `aws-sdk-s3` | Rust から S3 を操作する crate | learn5 の `src/main.rs` | [learn5](learn5/README.md) |

## 9. 操作の道具

| 用語 | 意味 | この教材での例 | 初出 |
|---|---|---|---|
| kubectl | クラスタを操作するコマンド | `kubectl apply -f ...` | [learn1](learn1/README.md) |
| `kubectl diff` | apply したらクラスタ上の状態がどう変わるかを、差分で見せる | learn4 で `value` が `valueFrom` に変わる差分 | [learn4](learn4/README.md) |
| kubeconfig | `kubectl` などがクラスタに接続するための設定ファイル | `/etc/rancher/k3s/k3s.yaml` | [learn2](learn2/README.md) |
| k9s | ターミナルで動く Kubernetes の画面 | `k9s --kubeconfig /etc/rancher/k3s/k3s.yaml` | [learn2](learn2/README.md) |
| `multipass mount` / `multipass transfer` | Mac のディレクトリを VM に共有する / ファイルを VM にコピーする | この環境では mount の中身が空になるので `transfer -r learnN` を使う | [learn2](learn2/README.md) |
