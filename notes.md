# 確認メモ

確認したバージョン・API・詰まった点を、確認日と URL つきで残す。

## 目次

- [この教材の環境](#この教材の環境)
- [MinIO のイメージの配布終了](#minio-のイメージの配布終了)
- [MinIO の Helm Chart 5.4.0](#minio-の-helm-chart-540)
- [k3s の保存先と Secret](#k3s-の保存先と-secret)
- [kubelet のイメージ GC](#kubelet-のイメージ-gc)
- [multipass mount](#multipass-mount)
- [nginx イメージのテンプレート展開](#nginx-イメージのテンプレート展開)
- [Bitnami の Chart とイメージ](#bitnami-の-chart-とイメージ)
- [その他の気づき](#その他の気づき)

## この教材の環境

確認日: 2026-09-30

| 部品 | 版・値 | 確かめ方 |
|---|---|---|
| macOS | 15.3.1 (24D70) | `sw_vers` |
| Multipass | 1.16.1+mac（1.16.4 が出ている） | `multipass version` |
| VM | `k3s-master`、Ubuntu 22.04.5、2 CPU、メモリ 1.9GiB、ディスク 20G | `multipass info k3s-master` |
| k3s | v1.34.5+k3s1、containerd 2.1.5-k3s1 | `kubectl get nodes -o wide` |
| Helm | v3.20.1 | `helm version --short` |
| SSD | Mac の `/Volumes/SSD-PGU3`（932G）を NFS で VM の `/mnt/ssd` に | `df -h /mnt/ssd` |
| `/etc/exports` | `/Volumes/SSD-PGU3 -alldirs -maproot=root -network 192.168.64.0 -mask 255.255.255.0` | `cat /etc/exports` |

- VM の `/etc/fstab` に NFS の行は無い。VM は 2026-03-28 から再起動していないので、再起動後にマウントが戻るかは未確認（⚠ 未検証）
- VM のネットワークインターフェースは `enp0s1`
- 同じクラスタに、別リポジトリ learn-tracing の namespace `tracing` が同居している。この教材の作業では触らない

## MinIO のイメージの配布終了

確認日: 2026-09-30

- `minio/minio` と `minio/mc` は、Docker Hub（`registry-1.docker.io`）でも Quay（`quay.io`）でも、匿名でのマニフェスト取得が 401 になる。
  VM で `sudo k3s crictl pull quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z` も `401 Unauthorized` で失敗した
- 経緯（検索で確認、一次資料ではない）:
  - 2025-10-23 に MinIO が Community Edition のコンテナイメージの配布をやめた
  - 2026-09-11 に Docker Hub の `minio/minio`・`minio/mc` リポジトリが削除された
  - GitHub の `minio/minio` はアーカイブされ、ソースのみの配布になった
  - https://vonng.com/en/db/silo-is-coming/
  - https://www.chainguard.dev/unchained/secure-and-free-minio-chainguard-containers
  - https://github.com/milvus-io/milvus/issues/53430
- この VM の containerd には `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z` が残っている。learn3・learn4 はこれに固定した
- 控えとして、このイメージ（linux/arm64）を VM の `/home/ubuntu/minio-RELEASE.2024-12-18T13-15-44Z.tar`（58MB）に書き出した。
  消えたら `sudo k3s ctr images import /home/ubuntu/minio-RELEASE.2024-12-18T13-15-44Z.tar` で戻せる（⚠ 未検証: 戻す操作は試していない）
- 新しい VM では learn3 以降の MinIO を起動できない。代わりの S3 互換ストレージに移すかどうかは未定

## MinIO の Helm Chart 5.4.0

確認日: 2026-09-30

- リポジトリ `https://charts.min.io` は取得できた。最新は `5.4.0`（APP VERSION `RELEASE.2024-12-18T13-15-44Z`）
- 既定値（`helm show values minio-official/minio --version 5.4.0`、593 行）:
  - `mode: distributed`、`replicas: 16`
  - `resources.requests.memory: 16Gi`。メモリ 2GB の VM では `Insufficient memory` で `Pending` になることを確かめた
  - `persistence.size: 500Gi`
  - `service.type` / `consoleService.type` は `ClusterIP`
  - `users` にユーザー `console`（policy `consoleAdmin`）。これがあると `post-install,post-upgrade` の Job が `quay.io/minio/mc` で作られる。
    `users: []` にすると Job は作られない（`helm template` で確認）
- Chart の Deployment には readinessProbe も livenessProbe も無い（`helm get manifest` に `probe` が 0 件）
- 2026-03-29 の install では、後処理の Job `minio-post-job` が `BackoffLimitExceeded` で失敗し、Release が `failed`（`context canceled`）になっていた。当時のログは残っておらず、原因は分からない
- `helm uninstall` は、失敗した後処理の Job を消さなかった

## k3s の保存先と Secret

確認日: 2026-09-30

- ノード 1 台の k3s は etcd ではなく SQLite（kine）を使う。`/var/lib/rancher/k3s/server/db/state.db`。`k3s etcd-snapshot ls` は `etcd datastore disabled`
- Secret は `kine` テーブルの `/registry/secrets/<namespace>/<name>` の行に protobuf（先頭 `k8s\x00`）で入り、値は平文のバイト列だった
- `/var/lib/rancher/k3s/server/cred/encryption-config.json` は無い。Secret の暗号化（`--secrets-encryption`）は有効になっていない
- `kubectl apply` で `stringData` の Secret を作ると、`kubectl.kubernetes.io/last-applied-configuration` に平文で残る

## kubelet のイメージ GC

確認日: 2026-09-30

- learn5 の `docker build` 中（2026-10-01 00:06:10）に VM のディスク使用率が 85% を超え、kubelet が未使用のイメージを消した（`image_gc_manager.go ... Removing image to free bytes`）
- 作業前後の `k3s ctr images ls` を比べて無くなっていたもの: `docker.io/minio/minio:latest`、`quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z`、
  `minio-rust-client:latest`、`amazon/aws-cli:latest`、`busybox:latest`。learn-tracing が使う `learn6-app:latest` と `jaeger:2.20.0` は動いている Pod が使っているので残った
- `docker builder prune -af` で 2GB 近く空き、使用率は 59% に戻った

## multipass mount

確認日: 2026-09-30

- `multipass info` の Mounts には `learn2`〜`learn6` が登録されているが、VM の `/home/ubuntu/learnN` は空だった
- `multipass transfer -r learnN k3s-master:/home/ubuntu/` で代用する（1.16.1 で `-r` が使える）

## nginx イメージのテンプレート展開

確認日: 2026-09-30

- URL: https://github.com/nginx/docker-nginx/blob/master/entrypoint/20-envsubst-on-templates.sh
- テンプレートのディレクトリは `NGINX_ENVSUBST_TEMPLATE_DIR`（既定 `/etc/nginx/templates`）
- 拡張子は `NGINX_ENVSUBST_TEMPLATE_SUFFIX`（既定 `.template`）。出力時にこの拡張子を外す
- 出力先は `NGINX_ENVSUBST_OUTPUT_DIR`（既定 `/etc/nginx/conf.d`）
- 置き換える変数は、定義されている環境変数のうち `NGINX_ENVSUBST_FILTER` に合う名前だけ。定義されていない `$uri` などは残る
- learn1 が使う `nginx:1.23` に同じスクリプトが入っているかは、タグのソースでは確かめていない（⚠ 未検証）

## Bitnami の Chart とイメージ

確認日: 2026-09-30（出典はこのリポジトリの learn6/README.md とコミット `3f9eeae`。一次資料の URL は未確認）

- 旧 learn6/README.md には「Bitnami は 2025年8月28日以降、無料で利用できるイメージ・Chart の範囲を制限した」とあり、
  そのため learn6 は公式 MinIO Chart（`https://charts.min.io/`）に切り替えている
- VM には `bitnami` のリポジトリ登録が残っている（`helm repo list`）
- 一次資料（Bitnami の告知）の URL は未確認（⚠ 未検証）

## その他の気づき

確認日: 2026-09-30

- learn2 の `test-pod.yaml` は `sleep 3600` なので 1 時間ごとに再起動する。消し忘れた Pod が 186 日で `RESTARTS 4462` になっていた
- learn5 の Dockerfile は `Cargo.lock` をコピーしていなかった（ビルドのたびに依存の版が変わりうる）。コピーするように直した
- learn5 の出力は `hello.txt (30 bytes)`。旧 README の `31 bytes` は誤り
- `learn1/config.yaml` と `learn1/myapp-config.yaml` は同じ ConfigMap（コメントの有無だけが違う）
