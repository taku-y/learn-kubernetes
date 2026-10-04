# Helm で RustFS を入れ直す

learn3〜learn5 では、RustFS のマニフェスト（Namespace・PVC・Deployment・Service・ConfigMap・Secret）を手で書きました。
このステップでは、RustFS の開発元が配布している **Helm Chart** で同じものを入れ直し、`install`・`upgrade`・`rollback` を行います。

このステップの問いは次のひとつです。

> **Helm は、手書きのマニフェストの代わりに何を作り、変更の履歴をどこに持っているのか。**

新しく扱うのは Helm（Chart・Values・Release・Revision）です。

## 目次

- [前提条件](#前提条件)
- [1. Helm の 4 つの言葉](#1-helm-の-4-つの言葉)
- [2. learn3〜learn5 の RustFS を片付ける](#2-learn3learn5-の-rustfs-を片付ける)
- [3. Helm を入れて Chart を探す](#3-helm-を入れて-chart-を探す)
- [4. valuesyaml で上書きするもの](#4-valuesyaml-で上書きするもの)
- [5. helm install](#5-helm-install)
- [6. Helm が作ったもの](#6-helm-が作ったもの)
- [7. helm upgrade と helm rollback](#7-helm-upgrade-と-helm-rollback)
- [8. 出力の読み方](#8-出力の読み方)
- [9. 落とし穴](#9-落とし穴)
- [演習](#演習)
- [クリーンアップ](#クリーンアップ)
- [まとめ](#まとめ)

## 前提条件

- learn2 の StorageClass `local-ssd` と、`/mnt/ssd` のマウント
- `kubectl` と `helm` を `sudo` なしで使える（[vm-setup.md](../vm-setup.md#2-kubectl-と-helm-を-sudo-なしで使う)）
- learn5 まで進めていれば、namespace `rustfs` に手書きの RustFS が残っている（2 で片付けます）

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn6 k3s-master:/home/ubuntu/
```

## 1. Helm の 4 つの言葉

| 言葉 | 実体 | このステップでの例 |
|---|---|---|
| **Chart** | マニフェストの**ひな形**の集まり。`{{ .Values.xxx }}` の穴が空いている | `rustfs/rustfs` の版 `1.0.1` |
| **Values** | 穴に入れる値。Chart に既定値があり、`-f values.yaml` で上書きする | `learn6/values.yaml` |
| **Release** | Chart に Values を入れて、クラスタに入れたもの。名前で呼ぶ | `rustfs` |
| **Revision** | Release の版の番号。install で 1、upgrade・rollback のたびに 1 増える | 1 → 2 → 3 |

learn3 の手書きとの違いは、**マニフェストを自分で持たない**ことです。
自分が持つのは「既定値から変えたい値」だけで、残りは Chart の作者が書いたひな形に任せます。

## 2. learn3〜learn5 の RustFS を片付ける

Helm の RustFS も namespace `rustfs`、NodePort 30900・30901 を使うので、手書きの RustFS を先に消します。

```bash
# VM 内
kubectl delete -f /home/ubuntu/learn4/rustfs.yaml   # namespace ごと消え、ConfigMap・Secret も消える
kubectl delete pv rustfs-pv
sudo rm -rf /mnt/ssd/rustfs-storage
```

## 3. Helm を入れて Chart を探す

```bash
# VM 内
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version --short
```

```
v3.20.1+ga2369ca
```

Chart は**リポジトリ**で配布されます。RustFS のリポジトリを `rustfs` という名前で登録します。

```bash
# VM 内
helm repo add rustfs https://charts.rustfs.com
helm repo update rustfs
helm search repo rustfs/rustfs --versions | head -4
```

```
NAME         	CHART VERSION	APP VERSION   	DESCRIPTION
rustfs/rustfs	1.0.1        	1.0.1         	RustFS helm chart to deploy RustFS on kubernete...
rustfs/rustfs	1.0.0        	1.0.0         	RustFS helm chart to deploy RustFS on kubernete...
rustfs/rustfs	0.12.0       	1.0.0-beta.12 	RustFS helm chart to deploy RustFS on kubernete...
```

`CHART VERSION` は Chart（ひな形）の版、`APP VERSION` は Chart が入れる RustFS の版です。
`1.0.1` の Chart は、learn3 で固定したのと同じ `rustfs/rustfs:1.0.1` のイメージを使います。

## 4. values.yaml で上書きするもの

Chart の既定値は `helm show values rustfs/rustfs --version 1.0.1` で見られます（477 行あります）。
`values.yaml` では、そのうち次のものを上書きします。

| キー | 既定値 | `values.yaml` | 上書きする理由 |
|---|---|---|---|
| `mode.standalone.enabled` / `mode.distributed.enabled` | `false` / `true`（Pod 4 つの分散構成） | `true` / `false` | ノードが 1 台しかない |
| `secret.rustfs.access_key` / `secret_key` | 空 | `learnadmin` / `learn-dummy-secret`（学習用のダミー値） | 空や `rustfsadmin` のままだと、Chart が展開を止める（9 を参照） |
| `image.initImage.tag` | `stable` | `1.37` | 初期化用コンテナ（busybox）の版を固定する |
| `storageclass.name` | `local-path` | `local-ssd` | learn2 の SSD に置く |
| `storageclass.dataStorageSize` / `logStorageSize` | `256Mi` / `256Mi` | `50Gi` / `1Gi` | 用意する PV（`pv.yaml`）に合わせる |
| `service.type` | `ClusterIP` | `NodePort`（30900 / 30901） | Mac のブラウザから見る |
| `ingress.enabled` | `true`（`ingressClassName: nginx`） | `false` | この k3s には nginx の Ingress Controller が無い |

認証情報が learn3〜learn5 と違うのは、この Chart が既定値の `rustfsadmin` を受け付けないからです。

`values-v2.yaml` は `values.yaml` に `resources`（要求 CPU 100m・メモリ 256Mi、上限 CPU 500m・メモリ 512Mi）を足したものです。7 で使います。

### PV を 2 つ用意する

Chart は PVC を **2 つ**（データ用の `rustfs-data` とログ用の `rustfs-logs`）作りますが、PV は作りません。
`local-ssd` は PV を自動で作らない StorageClass（learn2）なので、PV を先に用意します。

`pv.yaml` の 2 つの PV には `claimRef`（この PV をどの PVC に使わせるか）を書いてあります。
書かないと、ログ用の 1Gi の PVC がデータ用の 50Gi の PV と結ばれる、といった入れ違いが起こりえます。

```bash
# VM 内
cd /home/ubuntu/learn6
sudo mkdir -p /mnt/ssd/rustfs-helm-storage/data /mnt/ssd/rustfs-helm-storage/logs
kubectl apply -f pv.yaml
kubectl get pv
```

```
NAME                  CAPACITY   ...   STATUS      CLAIM                STORAGECLASS   ...
rustfs-helm-data-pv   50Gi       ...   Available   rustfs/rustfs-data   local-ssd      ...
rustfs-helm-logs-pv   1Gi        ...   Available   rustfs/rustfs-logs   local-ssd      ...
```

まだ PVC が無いので `Available` ですが、`CLAIM` 欄には予約した PVC の名前が出ています。

## 5. helm install

```bash
# VM 内
helm install rustfs rustfs/rustfs --version 1.0.1 \
  --namespace rustfs --create-namespace -f values.yaml
```

```
NAME: rustfs
LAST DEPLOYED: Sun Oct  4 18:43:25 2026
NAMESPACE: rustfs
STATUS: deployed
REVISION: 1
NOTES:
1. Watch all pods come up
  kubectl get pods -w -l app.kubernetes.io/name=rustfs -n rustfs
```

| 引数 | 意味 |
|---|---|
| `rustfs`（1 つ目） | Release の名前 |
| `rustfs/rustfs` | 使う Chart（リポジトリ名/Chart 名） |
| `--version 1.0.1` | Chart の版を固定する。付けないと、その時点の最新になる |
| `--namespace rustfs --create-namespace` | 入れる先の namespace。無ければ作る |
| `-f values.yaml` | 既定値を上書きする値 |

`helm install` は 1 秒で戻り、Pod は 3 秒後に `PodInitializing`（初期化用コンテナの実行中）、17 秒後に Ready になりました。

## 6. Helm が作ったもの

```bash
# VM 内
kubectl get all,pvc,cm,secret,sa -n rustfs
```

```
NAME                          READY   STATUS    RESTARTS   AGE
pod/rustfs-595c56d587-lczcv   1/1     Running   0          23s

NAME                 TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                         AGE
service/rustfs-svc   NodePort   10.43.164.196   <none>        9000:30900/TCP,9001:30901/TCP   24s
...
NAME                                STATUS   VOLUME                CAPACITY   ...
persistentvolumeclaim/rustfs-data   Bound    rustfs-helm-data-pv   50Gi       ...
persistentvolumeclaim/rustfs-logs   Bound    rustfs-helm-logs-pv   1Gi        ...

NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      25s
configmap/rustfs-config      8      25s

NAME                                  TYPE                 DATA   AGE
secret/rustfs-secret                  Opaque               2      25s
secret/sh.helm.release.v1.rustfs.v1   helm.sh/release.v1   1      25s

NAME                     SECRETS   AGE
serviceaccount/default   0         25s
serviceaccount/rustfs    0         25s
```

Helm が実際に apply したマニフェストは `helm get manifest rustfs -n rustfs` で見られます。learn4 の手書きと並べると次のとおりです。

| リソース | learn4（手書き、3 ファイル 105 行） | learn6（Chart が生成、234 行） |
|---|---|---|
| Namespace | `rustfs.yaml` に書いた | `--create-namespace` で Helm が作る（Chart の外） |
| PVC | `rustfs-pvc` 1 つ | `rustfs-data` と `rustfs-logs` の 2 つ。ログも SSD に残る |
| Deployment | `rustfs` | `rustfs`。初期化用コンテナ・livenessProbe・`readOnlyRootFilesystem` が付く |
| Service | `rustfs` | `rustfs-svc`。クラスタ内の名前は `rustfs-svc.rustfs.svc:9000` |
| 認証情報 | ConfigMap と Secret から 1 つずつ `valueFrom` | Secret `rustfs-secret` に 2 つとも入れ、`envFrom` で丸ごと渡す |
| その他の設定 | env に直書き | ConfigMap `rustfs-config`（`RUSTFS_VOLUMES` など 8 個）を `envFrom` で渡す |
| ServiceAccount | なし | `rustfs` |

Chart が作ったリソースには、Helm の管理下にあることを示すラベルが付きます。

```bash
# VM 内
kubectl get deploy -n rustfs rustfs -o jsonpath="{.metadata.labels}"
```

```
{"app.kubernetes.io/instance":"rustfs","app.kubernetes.io/managed-by":"Helm","app.kubernetes.io/name":"rustfs","app.kubernetes.io/version":"1.0.1","helm.sh/chart":"rustfs-1.0.1"}
```

そして **Release の記録そのものが Secret** です。`sh.helm.release.v1.rustfs.v1` が Revision 1 の記録で、
中には Chart・Values・生成したマニフェストが圧縮して入っています。Helm はクラスタの外に状態を持ちません。

## 7. helm upgrade と helm rollback

### 7-1. upgrade: 要求と上限を足す

```bash
# VM 内
helm upgrade rustfs rustfs/rustfs --version 1.0.1 --namespace rustfs -f values-v2.yaml
kubectl get pod -n rustfs -l app.kubernetes.io/name=rustfs \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.containers[0].resources}{"\n"}{end}'
```

upgrade の 2 秒後の Pod です。

```
rustfs-db75f5b99-b64kc Pending {"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}
```

新しい Pod には `resources` が入っています。**古い Pod はもういません。**
この Chart の Deployment は `maxSurge: 0`（新しい Pod を先に増やさない）・`maxUnavailable: 1` なので、
古い Pod を止めてから新しい Pod を作ります。learn4 で見た「新旧 2 つの RustFS が同じデータを開く」時間は無くなりますが、
新しい Pod が Ready になるまでの間（readinessProbe は起動 10 秒後から）、RustFS に届く Pod がありません。

```bash
# VM 内
helm history rustfs -n rustfs
```

```
REVISION	UPDATED                 	STATUS    	CHART       	APP VERSION	DESCRIPTION
1       	Sun Oct  4 18:43:25 2026	superseded	rustfs-1.0.1	1.0.1      	Install complete
2       	Sun Oct  4 18:44:01 2026	deployed  	rustfs-1.0.1	1.0.1      	Upgrade complete
```

### 7-2. rollback: Revision 1 に戻す

```bash
# VM 内
helm rollback rustfs 1 -n rustfs
kubectl rollout status deploy/rustfs -n rustfs
helm history rustfs -n rustfs
```

```
REVISION	UPDATED                 	STATUS    	CHART       	APP VERSION	DESCRIPTION
1       	Sun Oct  4 18:43:25 2026	superseded	rustfs-1.0.1	1.0.1      	Install complete
2       	Sun Oct  4 18:44:01 2026	superseded	rustfs-1.0.1	1.0.1      	Upgrade complete
3       	Sun Oct  4 18:44:16 2026	deployed  	rustfs-1.0.1	1.0.1      	Rollback to 1
```

rollback は Revision 1 に**戻る**のではなく、Revision 1 と同じ内容の **Revision 3 を新しく作ります**。履歴は消えません。

```
rustfs-595c56d587-ztkbk Running {}
```

`resources` の無い Pod に戻りました。Pod 名の `595c56d587` は Revision 1 と同じです。
Pod のひな形が同じなので、Deployment は Revision 1 のときの ReplicaSet を使い回しています（`kubectl get rs -n rustfs` で、
`rustfs-595c56d587` が `DESIRED 1`、`rustfs-db75f5b99` が `DESIRED 0` になっています）。

```bash
# VM 内
kubectl get secret -n rustfs -l owner=helm
```

```
NAME                           TYPE                 DATA   AGE
sh.helm.release.v1.rustfs.v1   helm.sh/release.v1   1      64s
sh.helm.release.v1.rustfs.v2   helm.sh/release.v1   1      27s
sh.helm.release.v1.rustfs.v3   helm.sh/release.v1   1      13s
```

Revision ごとに Secret が 1 つ増えています。

## 8. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| `helm install` の `STATUS: deployed` | Helm がマニフェストを apply し終えた。**Pod が動いたという意味ではない**（9 を参照） |
| `helm history` の `superseded` | 後の Revision に置き換えられた |
| `helm history` の `DESCRIPTION` | `Install complete`・`Upgrade complete`・`Rollback to N` |
| `helm get values rustfs -n rustfs --revision N` | その Revision で上書きした値（`USER-SUPPLIED VALUES`）。既定値は含まない |
| PV の `CLAIM` 欄 | `Available` でも、`claimRef` で予約した PVC の名前が出る |
| Pod 名の真ん中 | ReplicaSet の識別子。Pod のひな形が同じなら同じになる |

## 9. 落とし穴

- **既定の認証情報のままだと、Chart は何も作りません。**`secret.rustfs.*` を書かずに `helm template` すると、次のエラーで止まります。
  ダミー値でも、既定値でない値を書きます（`secret.allowInsecureDefaults: true` で既定値を許すこともできます）

  ```
  Error: execution error at (rustfs/templates/secret.yaml:15:4): secret.rustfs.access_key and secret.rustfs.secret_key must be set to non-default, non-empty values, or set secret.existingSecret to a Secret you control. To opt into the well-known default credentials for local development only, set secret.allowInsecureDefaults=true.
  ```

- **`STATUS: deployed` でも Pod が動いているとは限りません。**Helm は apply が通った時点で `deployed` を返します。
  Pod が Ready になるまで待たせたいときは `helm upgrade --wait` を付けます（演習 1）
- **`helm uninstall` は PVC を消しません。**Chart の PVC には `helm.sh/resource-policy: keep` の注釈が付いていて、uninstall すると次のように出ます

  ```
  These resources were kept due to the resource policy:
  [PersistentVolumeClaim] rustfs-data
  [PersistentVolumeClaim] rustfs-logs

  release "rustfs" uninstalled
  ```

  PVC も PV も `Bound` のまま残ります。同じ名前で `helm install` し直すと、Release は Revision 1 から始まり、残った PVC をそのまま使います。
  実際に、入れ直した後も、前に作ったバケット `helm-bucket` が見えました。データまで消すときは、PVC・PV・SSD のディレクトリを自分で消します
- **namespace ごと消すと、PV が `Released` になります。**PVC が消えると、`Retain` の PV には前の PVC への予約（`spec.claimRef` の `uid`）が残ります（learn2 と同じ現象）。
  そのまま入れ直すと、新しい PVC はこの PV と結ばれません。`kubectl delete -f pv.yaml` で PV を作り直します。データは SSD に残ります
  （⚠ 未検証: RustFS の Chart では試していません。MinIO の Chart を使っていた 2026-09-30 に、`Released` になるのを確かめました）
- **Ingress は既定で有効です。**`ingress.enabled: false` を書かないと、`ingressClassName: nginx`・ホスト名 `console.rustfs.com` の Ingress が作られます。
  この k3s の Ingress Controller は Traefik なので、作られても使われません
- **Chart のリポジトリは `bitnami` ではありません。**以前の learn6 は Bitnami の MinIO Chart を使っていましたが、
  Bitnami が 2025 年 8 月から無償で使えるイメージと Chart の範囲を狭めたので、MinIO 公式の Chart に替え、さらに RustFS に替えました
  （⚠ 未検証: Bitnami の告知の一次資料は確認していません）

## 演習

1. `helm upgrade ... -f values.yaml --set resources.requests.memory=16Gi` を実行し、`STATUS: deployed` と Pod の `Pending`
   （`kubectl describe pod` の `Insufficient memory`）を見比べる。`--wait --timeout 1m` を付けると何が変わるかも見る。最後に `helm rollback` で戻す
2. `helm get manifest rustfs -n rustfs` を learn4 の `rustfs.yaml` と見比べる。Chart の Deployment にある `livenessProbe` と
   `readOnlyRootFilesystem` が何をするものかを調べる
3. `pv.yaml` から `claimRef` を消して入れ直し、2 つの PVC がどちらの PV と結ばれるかを見る
4. `kubectl get secret sh.helm.release.v1.rustfs.v1 -n rustfs -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip | head -c 500`
   で、Release の記録の中身をのぞく
5. `helm test rustfs -n rustfs` を実行し、Chart に入っているテスト用の Pod（`rustfs-test-connection`）が何を確かめているかを見る

## クリーンアップ

このステップが最後なので、RustFS を残しても消しても構いません。消すときは次のとおりです。

```bash
# VM 内
helm uninstall rustfs -n rustfs
kubectl delete namespace rustfs      # uninstall で残った PVC も消える
kubectl delete -f pv.yaml
sudo rm -rf /mnt/ssd/rustfs-helm-storage
```

## まとめ

- Chart はマニフェストのひな形、Values はそこに入れる値。自分が持つのは既定値から変えたい値だけ
- Release の記録は、Revision ごとの Secret としてクラスタの中にある
- `rollback` は過去の Revision と同じ内容の新しい Revision を作る
- `STATUS: deployed` は apply が終わったという意味で、Pod が動いたかは別に確かめる
- Chart は作者の判断（既定の認証情報を拒む、PVC を残す、Pod を止めてから入れ替える）ごと入ってくる。`helm template` で中身を見てから入れる
