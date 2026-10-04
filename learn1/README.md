# Deployment・ConfigMap・Secret で nginx を動かす

書籍「つくって、壊して、直して学ぶ Kubernetes入門」(高橋あおい著) のハンズオンで書いたマニフェストの置き場所です。
このディレクトリには README がなかったので、後から（2026-09-30）足しました。マニフェストは当時のまま手を入れていません。

このステップの問いは次のひとつです。

> **nginx の設定ファイルと、その中に埋め込む値を、コンテナイメージの外からどう渡すか。**

新しく扱うリソースは Deployment・ConfigMap・Secret の 3 つです。

> ⚠ 未検証: この README のコマンドと出力は、2026-09-30 の時点では再実行していません。
> ハンズオン当時にどのクラスタで動かしたかの記録も残っていません。

## 目次

- [前提条件](#前提条件)
- [1. ディレクトリにあるもの](#1-ディレクトリにあるもの)
- [2. 3 つのリソースのつながり](#2-3-つのリソースのつながり)
- [3. nginx が設定ファイルを組み立てる仕組み](#3-nginx-が設定ファイルを組み立てる仕組み)
- [4. 値を Secret に移した経緯](#4-値を-secret-に移した経緯)
- [5. 実行方法](#5-実行方法)
- [6. 出力の読み方](#6-出力の読み方)
- [7. 落とし穴](#7-落とし穴)
- [演習](#演習)
- [クリーンアップ](#クリーンアップ)
- [まとめ](#まとめ)

## 前提条件

- `kubectl` から操作できる Kubernetes クラスタがあること。書籍の手順で作ったクラスタを想定しています
  （learn2 で作る k3s クラスタでも動くはずですが、試していません）
- 前のステップはありません。このステップが最初です

## 1. ディレクトリにあるもの

| ファイル | kind | `metadata.name` | 中身 |
|---|---|---|---|
| [myapp.yaml](myapp.yaml) | Deployment | `myapp` | `docker.io/nginx:1.23` のコンテナを 1 つ動かす |
| [myapp-config.yaml](myapp-config.yaml) | ConfigMap | `myapp-config` | nginx の設定ファイルのテンプレート `default.conf.template` |
| [myapp-secret.yaml](myapp-secret.yaml) | Secret | `myapp-secret` | 環境変数 `MY_ENV` に入れる値 |
| [config.yaml](config.yaml) | ConfigMap | `myapp-config` | `myapp-config.yaml` と同じ内容に、書籍の注釈 `（1）` のコメントが付いたもの |

`config.yaml` と `myapp-config.yaml` は `metadata.name` が同じなので、どちらを apply しても同じ ConfigMap になります。
両方を apply すると、後から apply した方で上書きされます（中身が同じなので結果は変わりません）。

namespace を指定していないので、どのリソースも `default` namespace に作られます。

## 2. 3 つのリソースのつながり

Deployment は ConfigMap と Secret を**名前で参照**しています。ファイルどうしが import しているわけではなく、
クラスタ上に同じ名前のリソースがあれば結びつきます。

| 参照元（`myapp.yaml` の中） | 参照先 | 渡し方 |
|---|---|---|
| `volumes[].configMap.name: myapp-config` | ConfigMap `myapp-config` | ファイルとして `/etc/nginx/templates` にマウントする。キー名 `default.conf.template` がファイル名になる |
| `env[].valueFrom.secretKeyRef` (`name: myapp-secret`, `key: MY_ENV`) | Secret `myapp-secret` のキー `MY_ENV` | 環境変数 `MY_ENV` として渡す |

Secret の値 `a3ViZXJuZXRlcw==` は base64 で、デコードすると `kubernetes` です。

```bash
# Mac 側
echo a3ViZXJuZXRlcw== | base64 -d
# kubernetes
```

base64 は暗号化ではありません。マニフェストを読める人には値が読めます。

## 3. nginx が設定ファイルを組み立てる仕組み

ConfigMap に入っているのは設定ファイルそのものではなく、`$MY_ENV` を含む**テンプレート**です。

```nginx
server {
    location / {
        return 200 'Hello $MY_ENV';
        add_header Content-Type text/plain;
    }
}
```

公式の nginx イメージは、起動時に `/etc/nginx/templates/*.template` を読み、環境変数を `envsubst` で埋めて
`/etc/nginx/conf.d/` に書き出します（拡張子 `.template` を外した名前、ここでは `default.conf`）。
確認した資料は [notes.md](../notes.md) にあります。

そのため、コンテナの中では次の順に組み立てられます。

1. Secret の `kubernetes` が環境変数 `MY_ENV` に入る
2. ConfigMap のテンプレートが `/etc/nginx/templates/default.conf.template` に置かれる
3. nginx の起動スクリプトが `$MY_ENV` を `kubernetes` に置き換えて `/etc/nginx/conf.d/default.conf` を作る
4. nginx は `/` へのリクエストに `Hello kubernetes` を返す

イメージを作り直さずに、応答の文面（ConfigMap）と埋め込む値（Secret）を別々に差し替えられるのがこの構成の要点です。

## 4. 値を Secret に移した経緯

コミット履歴を見ると、ハンズオンは 2 段階で進めています。

| 段階 | コミット | `MY_ENV` の渡し方 | 返るはずの応答 |
|---|---|---|---|
| 1 | `b72217c` (2026-03-08) | `myapp.yaml` に `value: "World"` と直書き | `Hello World` |
| 2 | `eb9511d` (2026-03-08) | `secretKeyRef` で Secret `myapp-secret` から読む | `Hello kubernetes` |

## 5. 実行方法

ConfigMap と Secret を先に作り、最後に Deployment を作ります。
順番を逆にすると、参照先が見つからずに Pod が起動しません（[7. 落とし穴](#7-落とし穴)）。

```bash
# kubectl が使える端末で、learn1/ の中で実行
kubectl apply -f myapp-config.yaml
kubectl apply -f myapp-secret.yaml
kubectl apply -f myapp.yaml
```

Pod が `Running` になるのを待ちます。

```bash
kubectl get pod -l app=myapp -w
```

Service を作っていないので、`port-forward` で手元から nginx に届くようにします。

```bash
kubectl port-forward deployment/myapp 8080:80
```

別の端末で:

```bash
curl http://localhost:8080/
```

## 6. 出力の読み方

`curl` の応答が `Hello kubernetes` なら、Secret → 環境変数 → テンプレート → nginx の設定、の全部がつながっています。

| 応答 | 読み方 |
|---|---|
| `Hello kubernetes` | すべてつながっている |
| `Hello ` （値が空） | テンプレートは読まれたが、環境変数 `MY_ENV` が空 |
| nginx の標準ページ（`Welcome to nginx!`） | テンプレートが `/etc/nginx/templates` に置かれていない。ConfigMap のマウントを疑う |

コンテナの中で、組み立てられた設定ファイルを直接見ることもできます。

```bash
kubectl exec deployment/myapp -- cat /etc/nginx/conf.d/default.conf
kubectl exec deployment/myapp -- printenv MY_ENV
```

## 7. 落とし穴

- **ConfigMap や Secret を後から変えても、動いている Pod には反映されません。**環境変数は Pod の起動時に決まり、
  nginx のテンプレートも起動時に一度だけ展開されます。変えたら `kubectl rollout restart deployment/myapp` で Pod を作り直します
- **参照先がないと Pod が起動しません。**Secret を作る前に Deployment を apply すると、Pod は
  `CreateContainerConfigError` になります（⚠ 未検証: このリポジトリでは確かめていません）
- **nginx の変数とぶつかることがあります。**`envsubst` は環境変数に存在する名前だけを置き換えるので、
  `$uri` のような nginx 自身の変数は、同じ名前の環境変数がなければそのまま残ります

## 演習

1. `myapp-secret.yaml` の `MY_ENV` を別の文字列の base64（`echo -n hello | base64`）に変えて apply し、
   `curl` の応答が変わらないことを確かめる。そのあと `kubectl rollout restart deployment/myapp` をして、応答が変わることを確かめる
2. `myapp.yaml` の `mountPath` を `/etc/nginx/template`（`s` を消す）に変えて apply し、応答が何になるかを見る
3. `myapp.yaml` の `secretKeyRef.key` を存在しないキー名に変えて apply し、`kubectl get pod` と `kubectl describe pod` に何が出るかを見る
4. `echo -n` を付けずに `echo kubernetes | base64` で Secret を作り直し、応答の末尾がどうなるかを見る

## クリーンアップ

```bash
kubectl delete -f myapp.yaml
kubectl delete -f myapp-secret.yaml
kubectl delete -f myapp-config.yaml
```

次の learn2 ではクラスタ自体を作り直すので、このステップのリソースを残しておく必要はありません。

## まとめ

- Deployment は ConfigMap と Secret を**名前で**参照する。ファイルの位置ではない
- ConfigMap はファイルとして、Secret は環境変数として渡せる（どちらもその逆もできる）
- 公式の nginx イメージは `/etc/nginx/templates` のテンプレートを起動時に環境変数で埋める
- Secret の値は base64 にすぎず、暗号化されていない
- 次の [learn2](../learn2/README.md) では、Mac Mini 上に自分で k3s クラスタを立てて、ストレージをつなぎます
