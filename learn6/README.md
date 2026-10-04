# Helm で MinIO を入れ直す

learn3〜learn5 では、MinIO のマニフェスト（Namespace・PVC・Deployment・Service）を手で書きました。
このステップでは、MinIO が配布している **Helm Chart** で同じものを入れ直し、`install`・`upgrade`・`rollback` を行います。

このステップの問いは次のひとつです。

> **Helm は、手書きのマニフェストの代わりに何を作り、変更の履歴をどこに持っているのか。**

新しく扱うのは Helm（Chart・Values・Release・Revision）です。

> learn3 と同じく、MinIO のイメージはもう配布されていません。この VM に残っているイメージで動かしています（[learn3](../learn3/README.md) の冒頭を参照）。
> Chart のリポジトリ `https://charts.min.io` は、2026-09-30 の時点ではまだ取得できました。

## 目次

- [前提条件](#前提条件)
- [1. Helm の 4 つの言葉](#1-helm-の-4-つの言葉)
- [2. learn3〜learn5 の MinIO を片付ける](#2-learn3learn5-の-minio-を片付ける)
- [3. Helm を入れて Chart を探す](#3-helm-を入れて-chart-を探す)
- [4. values.yaml で上書きするもの](#4-valuesyaml-で上書きするもの)
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
- learn5 まで進めていれば、namespace `minio` に手書きの MinIO が残っている（2 で片付けます）

```bash
# Mac 側（リポジトリのルートで）
multipass transfer -r learn6 k3s-master:/home/ubuntu/
```

## 1. Helm の 4 つの言葉

| 言葉 | 実体 | このステップでの例 |
|---|---|---|
| **Chart** | マニフェストの**ひな形**の集まり。`{{ .Values.xxx }}` の穴が空いている | `minio-official/minio` の版 `5.4.0` |
| **Values** | 穴に入れる値。Chart に既定値があり、`-f values.yaml` で上書きする | `learn6/values.yaml` |
| **Release** | Chart に Values を入れて、クラスタに入れたもの。名前で呼ぶ | `minio` |
| **Revision** | Release の版の番号。install で 1、upgrade・rollback のたびに 1 増える | 1 → 2 → 3 |

learn3 の手書きとの違いは、**マニフェストを自分で持たない**ことです。
自分が持つのは「既定値から変えたい値」だけで、残りは Chart の作者が書いたひな形に任せます。

## 2. learn3〜learn5 の MinIO を片付ける

Helm の MinIO も namespace `minio`、NodePort 30900・30901 を使うので、手書きの MinIO を先に消します。

```bash
# VM 内
kubectl delete -f /home/ubuntu/learn4/minio.yaml   # namespace ごと消え、ConfigMap・Secret・Job も消える
kubectl delete pv minio-pv
sudo rm -rf /mnt/ssd/minio-storage
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

Chart は**リポジトリ**で配布されます。MinIO 公式のリポジトリを `minio-official` という名前で登録します。

```bash
# VM 内
helm repo add minio-official https://charts.min.io
helm repo update
helm search repo minio-official/minio
```

```
NAME                	CHART VERSION	APP VERSION                 	DESCRIPTION
minio-official/minio	5.4.0        	RELEASE.2024-12-18T13-15-44Z	High Performance Object Storage
```

`CHART VERSION` は Chart（ひな形）の版、`APP VERSION` は Chart が入れる MinIO の版です。
この Chart は MinIO のイメージとして `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z` を使います。
learn3 で固定したのと同じ版で、この VM に残っています。

## 4. values.yaml で上書きするもの

Chart の既定値は `helm show values minio-official/minio --version 5.4.0` で見られます（500 行以上あります）。
`values.yaml` では、そのうち次のものを上書きします。

| キー | 既定値 | `values.yaml` | 上書きする理由 |
|---|---|---|---|
| `rootUser` / `rootPassword` | 空 | `minioadmin`（学習用のダミー値） | learn3〜learn5 と同じにする |
| `mode` | `distributed`（`replicas: 16` の分散構成） | `standalone` | ノードが 1 台しかない |
| `users` | ユーザー `console` を 1 人作る | `[]`（作らない） | 作るための Job が、配布の終わった `quay.io/minio/mc` を使う（9 を参照） |
| `persistence.storageClass` | 空（既定の `local-path`） | `local-ssd` | learn2 の SSD に置く |
| `persistence.size` | `500Gi` | `50Gi` | 用意する PV（`pv.yaml`）に合わせる |
| `service` / `consoleService` | `ClusterIP` | `NodePort` 30900 / 30901 | Mac のブラウザから見る |
| `resources.requests.memory` | `16Gi` | `256Mi` | VM のメモリは 2GB しかない（9 を参照） |

`values-v2.yaml` は `values.yaml` に `resources.limits`（CPU 500m、メモリ 512Mi の上限）を足したものです。7 で使います。

Chart は PVC を作りますが、PV は作りません。`local-ssd` は PV を自動で作らない StorageClass（learn2）なので、PV を先に用意します。

```bash
# VM 内
cd /home/ubuntu/learn6
sudo mkdir -p /mnt/ssd/minio-helm-storage
kubectl apply -f pv.yaml
```

## 5. helm install

```bash
# VM 内
helm install minio minio-official/minio --version 5.4.0 \
  --namespace minio --create-namespace -f values.yaml
```

```
NAME: minio
LAST DEPLOYED: Thu Oct  1 00:11:47 2026
NAMESPACE: minio
STATUS: deployed
REVISION: 1
...
```

| 引数 | 意味 |
|---|---|
| `minio` | Release の名前 |
| `minio-official/minio` | 使う Chart |
| `--version 5.4.0` | Chart の版を固定する。付けないと、その時点の最新になる |
| `--namespace minio --create-namespace` | 入れる先の namespace。無ければ作る |
| `-f values.yaml` | 既定値を上書きする値 |

`helm install` は 2 秒で戻り、Pod はその 2 秒後に Ready になりました。

## 6. Helm が作ったもの

```bash
# VM 内
kubectl get all,pvc,cm,secret,sa -n minio
```

```
NAME                         READY   STATUS    RESTARTS   AGE
pod/minio-7dbdf54bdd-tlwqq   1/1     Running   0          3s

NAME                    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
service/minio           NodePort   10.43.209.203   <none>        9000:30900/TCP   3s
service/minio-console   NodePort   10.43.112.84    <none>        9001:30901/TCP   3s

NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/minio   1/1     1            1           3s
...
NAME                          STATUS   VOLUME          CAPACITY   ACCESS MODES   STORAGECLASS   ...
persistentvolumeclaim/minio   Bound    minio-helm-pv   50Gi       RWO            local-ssd      ...

NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      5s
configmap/minio              5      5s

NAME                                 TYPE                 DATA   AGE
secret/minio                         Opaque               2      5s
secret/sh.helm.release.v1.minio.v1   helm.sh/release.v1   1      5s

NAME                      SECRETS   AGE
serviceaccount/default    0         5s
serviceaccount/minio-sa   0         5s
```

Helm が実際に apply したマニフェストは `helm get manifest` で見られます。learn3 の手書きと並べると次のとおりです。

| リソース | learn3（手書き、84 行） | learn6（Chart が生成、563 行） |
|---|---|---|
| Namespace | `minio.yaml` に書いた | `--create-namespace` で Helm が作る（Chart の外） |
| PVC | `minio-pvc` | `minio` |
| Deployment | `minio` | `minio` |
| Service | `minio` 1 つに API と Console の 2 ポート | `minio`（API）と `minio-console` の 2 つ |
| 認証情報 | env に直書き（learn4 で ConfigMap・Secret） | Secret `minio`（`rootUser`・`rootPassword`） |
| ConfigMap | なし | `minio`。mc で使うスクリプト 5 本（`add-policy` など）。`users: []` なので使われない |
| ServiceAccount | なし | `minio-sa` |

Chart が作ったリソースには、Helm の管理下にあることを示すラベルが付きます。

```bash
# VM 内
kubectl get deploy -n minio minio -o jsonpath="{.metadata.labels}"
```

```
{"app":"minio","app.kubernetes.io/managed-by":"Helm","chart":"minio-5.4.0","heritage":"Helm","release":"minio"}
```

そして **Release の記録そのものが Secret** です。`sh.helm.release.v1.minio.v1` が Revision 1 の記録で、
中には Chart・Values・生成したマニフェストが圧縮して入っています。Helm はクラスタの外に状態を持ちません。

## 7. helm upgrade と helm rollback

### 7-1. upgrade: 上限を足す

```bash
# VM 内
helm upgrade minio minio-official/minio --version 5.4.0 --namespace minio -f values-v2.yaml
kubectl rollout status deploy/minio -n minio
helm history minio -n minio
```

```
REVISION	UPDATED                 	STATUS    	CHART      	APP VERSION                 	DESCRIPTION
1       	Thu Oct  1 00:11:47 2026	superseded	minio-5.4.0	RELEASE.2024-12-18T13-15-44Z	Install complete
2       	Thu Oct  1 00:12:02 2026	deployed  	minio-5.4.0	RELEASE.2024-12-18T13-15-44Z	Upgrade complete
```

Pod のひな形が変わったので、Deployment が Pod を入れ替えます。入れ替わる途中の 2 つの Pod の `resources` を並べると、違いが見えます。

```bash
# VM 内
kubectl get pod -n minio -l app=minio \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.containers[0].resources}{"\n"}{end}'
```

```
minio-76855ddc6b-cddpr Running {"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}
minio-7dbdf54bdd-tlwqq Running {"requests":{"cpu":"100m","memory":"256Mi"}}
```

新しい Pod（`76855ddc6b`）には `limits` があり、古い Pod（`7dbdf54bdd`）にはありません。

### 7-2. rollback: Revision 1 に戻す

```bash
# VM 内
helm rollback minio 1 -n minio
kubectl rollout status deploy/minio -n minio
helm history minio -n minio
```

```
REVISION	UPDATED                 	STATUS    	CHART      	APP VERSION                 	DESCRIPTION
1       	Thu Oct  1 00:11:47 2026	superseded	minio-5.4.0	RELEASE.2024-12-18T13-15-44Z	Install complete
2       	Thu Oct  1 00:12:02 2026	superseded	minio-5.4.0	RELEASE.2024-12-18T13-15-44Z	Upgrade complete
3       	Thu Oct  1 00:12:04 2026	deployed  	minio-5.4.0	RELEASE.2024-12-18T13-15-44Z	Rollback to 1
```

rollback は Revision 1 に**戻る**のではなく、Revision 1 と同じ内容の **Revision 3 を新しく作ります**。履歴は消えません。

```
minio-76855ddc6b-cddpr Succeeded {"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}
minio-7dbdf54bdd-7bgfg Running {"requests":{"cpu":"100m","memory":"256Mi"}}
```

`limits` の無い Pod に戻りました。Pod 名の `7dbdf54bdd` は Revision 1 と同じです。
Pod のひな形が同じなので、Deployment は Revision 1 のときの ReplicaSet を使い回しています。

```bash
# VM 内
kubectl get secret -n minio -l owner=helm
```

```
NAME                          TYPE                 DATA   AGE
sh.helm.release.v1.minio.v1   helm.sh/release.v1   1      19s
sh.helm.release.v1.minio.v2   helm.sh/release.v1   1      4s
sh.helm.release.v1.minio.v3   helm.sh/release.v1   1      2s
```

Revision ごとに Secret が 1 つ増えています。

## 8. 出力の読み方

| 見るもの | 読み方 |
|---|---|
| `helm list` の `STATUS deployed` | Helm がマニフェストを apply し終えた。**Pod が動いたという意味ではない**（9 を参照） |
| `helm history` の `superseded` | 後の Revision に置き換えられた |
| `helm history` の `DESCRIPTION` | `Install complete`・`Upgrade complete`・`Rollback to N` |
| `helm get values minio -n minio --revision N` | その Revision で上書きした値（`USER-SUPPLIED VALUES`）。既定値は含まない |
| Pod 名の真ん中 | ReplicaSet の識別子。Pod のひな形が同じなら同じになる |

## 9. 落とし穴

- **`STATUS: deployed` でも Pod が動いているとは限りません。**`resources.requests.memory` を Chart の既定値 `16Gi` にして upgrade すると、
  Helm は `STATUS: deployed` と返しましたが、新しい Pod は次のイベントで `Pending` のままでした。ノードのメモリは約 2GB（`2013484Ki`）です

  ```
  Warning  FailedScheduling  default-scheduler  0/1 nodes are available: 1 Insufficient memory. ...
  ```

  古い Pod は動き続けたので、MinIO 自体は止まりませんでした。Pod まで待たせたいときは `helm upgrade --wait` を付けます
- **Chart の後処理の Job は、配布の終わったイメージを使います。**この Chart は install・upgrade の後に、
  `quay.io/minio/mc` のイメージで Job を動かし、ユーザーやバケットを作ります。`mc` のイメージは 2026-09-30 の時点で取得できません（401）。
  `users: []` にすると、この Job は作られません。
  この教材の以前の install（2026-03-29）でも、この Job が `BackoffLimitExceeded` で失敗し、Release が `failed` になっていました。
  その時点ではイメージは取得できたはずで、失敗の原因は分かっていません
- **`helm uninstall` は、失敗した後処理の Job と PV を残します。**PV は Chart の外で作ったものなので、自分で消します
- **uninstall の後に install し直すと、PV が `Released` のままで Pod が `Pending` になります。**
  `helm uninstall` で PVC が消えると、`Retain` の PV には前の PVC への予約（`spec.claimRef`）が残り、`Released` になります（learn2 と同じ現象）。
  2026-09-30 の片付けでも `minio-helm-pv` は `Released`（`CLAIM minio/minio`）になりました。新しい Pod には次のイベントが出ます

  ```
  0/1 nodes are available: 1 node(s) didn't find available persistent volumes to bind.
  ```

  PV を消して作り直すか、予約だけを外して `Available` に戻します。データは `Retain` なので残ります

  ```bash
  # VM 内
  kubectl get pv minio-helm-pv                                        # STATUS が Released か確かめる
  kubectl patch pv minio-helm-pv -p '{"spec":{"claimRef": null}}'     # 予約を外して Available に戻す
  kubectl delete pod -n minio <Pod 名>                                # Pending の Pod を作り直させる
  ```

  `claimRef` が自動で外れないのは、`Retain` がデータを守るための方針だからです。前の PVC のデータを、別の PVC が知らずに使うことを防ぎます
  （⚠ 未検証: `kubectl patch` の手順は 2026-03-29 の作業記録によるもので、2026-09-30 には実行していません）
- **Chart のリポジトリは `bitnami` ではありません。**Bitnami は 2025 年 8 月から無償で使えるイメージと Chart の範囲を狭めたので、MinIO 公式の Chart を使っています
  （⚠ 未検証: Bitnami の告知の一次資料は確認していません）

## 演習

1. `helm upgrade ... --set resources.requests.memory=16Gi` を実行し、`STATUS: deployed` と Pod の `Pending` を見比べる。
   `helm rollback` で直前の Revision に戻す
2. `helm get manifest minio -n minio` を learn4 の `minio.yaml` と見比べる。learn3 で書いた readinessProbe が、Chart の Deployment には無いことを確かめ、Pod の `READY` がいつ `1/1` になるかを learn3 と比べる
3. `values.yaml` の `users: []` を消して `helm upgrade --wait --timeout 2m` を実行し、何が起きるかを見る
   （Job `minio-post-job` がイメージを取得できずに止まる、と予想される）
4. `kubectl get secret sh.helm.release.v1.minio.v1 -n minio -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip | head -c 500`
   で、Release の記録の中身をのぞく

## クリーンアップ

このステップが最後なので、MinIO を残しても消しても構いません。消すときは次のとおりです。

```bash
# VM 内
helm uninstall minio -n minio
kubectl delete namespace minio      # PVC と残った Job も消える
kubectl delete -f pv.yaml
sudo rm -rf /mnt/ssd/minio-helm-storage
```

## まとめ

- Chart はマニフェストのひな形、Values はそこに入れる値。自分が持つのは既定値から変えたい値だけ
- Release の記録は、Revision ごとの Secret としてクラスタの中にある
- `rollback` は過去の Revision と同じ内容の新しい Revision を作る
- `STATUS: deployed` は apply が終わったという意味で、Pod が動いたかは別に確かめる
- Chart は作者のひな形に依存する。使うイメージが配布されなくなれば、Chart ごと動かなくなる
