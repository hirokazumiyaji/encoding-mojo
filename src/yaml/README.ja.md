# `yaml`

*[English](README.md) · 日本語*

純粋な Mojo による YAML のローダとエミッタです。PyYAML の `safe_load` と
`safe_dump` に合わせて作られており、関数名もキーワード引数も、暗黙の型付けも、
出力されるバイト列も同じです。

```mojo
from yaml import safe_dump, safe_load
```

ドキュメントは [`json`](../json) パッケージが使うのと同じ `Value` 型に読み込まれ
るため、YAML ドキュメントを変換なしに JSON として書き出せます。

```mojo
from json import dumps
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]\n")))
# {"name": "mojo", "tags": ["fast", "safe"]}
```

## 読み込み

```mojo
var doc = safe_load("""
name: mojo
version: 1.0
tags:
  - fast
  - safe
nested:
  key: value
""")

doc["name"].string()        # "mojo"
doc["version"].float()      # 1.0
doc["tags"][0].string()     # "fast"
len(doc["nested"])          # 1
```

`safe_load_all(text)` は `---` 区切りのストリームに含まれるすべてのドキュメントを
返します。`safe_load` はストリームに 2 つ以上あると、PyYAML とまったく同じように
送出します。

対応しているもの: ブロックとフローのコレクション、プレーン・単一引用符・二重引用
符・リテラル（`|`）・折りたたみ（`>`）スカラーとそのチョンピング指示子・明示イン
デント、コメント、ドキュメントマーカー、アンカーとエイリアス（`&a [1, *a]` のよう
な再帰的なものを含む）、マージキー（`<<`）、標準の `!!str`、`!!int`、`!!float`、
`!!bool`、`!!null` タグ。

マージキーがマージとして働くのはプレーンに書かれたときだけです。`'<<': 1` はただ
の文字列キーで、エミッタはリテラルな `<<` キーを引用して往復できるようにします。

失敗すると `YAMLError` を送出し、問題と位置を示します。

```text
could not find expected ':'
  in "<unicode string>", line 2, column 6
```

## 暗黙の型付けは YAML 1.1

PyYAML は YAML 1.1 を実装しており、このパッケージも YAML 1.2 ではなくそちらに
合わせています。この違いは実際に効いてきます。

| 書き方 | 読み込まれ方 | 補足 |
|--------|-------------|------|
| `yes`, `off`, `on` | bool | 1.2 には `true`/`false` しかない |
| `017`    | `15`           | 先頭のゼロは 8 進を意味する |
| `0o17`   | `"0o17"`       | 1.2 の 8 進接頭辞は 1.1 では数値ではない |
| `1_000`  | `1000`         | 数字は区切ってよい |
| `1e3`    | `"1e3"`        | 指数には明示的な符号が要るので、これは文字列 |
| `1:30`   | `90`           | 60 進。2 つ目以降の要素は 0-59 でなければならないので `1:60` は文字列 |
| `y`, `n` | `"y"`, `"n"`   | 1 文字は真偽値ではない |

## 書き出し

```mojo
safe_dump(doc)                            # ブロックスタイル、キーはソート
safe_dump(doc, sort_keys=False)           # 挿入順
safe_dump(doc, indent=4)
safe_dump(doc, default_flow_style=True)   # {a: [1, 2]}
safe_dump(doc, allow_unicode=True)        # UTF-8 をそのまま出す
safe_dump(doc, explicit_start=True)       # 先頭に ---
safe_dump_all(documents)                  # --- 区切りのストリーム
```

既定値は PyYAML のものです。つまりキーは**ソートされて**出力され、非 ASCII は
エスケープされて出力されます。スカラーは往復できるならプレーンで、できないなら
単一引用符で、制御文字やエスケープされた非 ASCII を含むなら二重引用符で書かれ
ます。2 回以上到達されるコレクションには `&idNNN` アンカーが付き、2 回目以降は
`*idNNN` になります。

## PyYAML との違い

- **マッピングのキーは常に文字列です。** PyYAML は任意のハッシュ可能なキーを許し
  ますが、`Value` のマッピングはテキストでキー付けされます。したがって数値・真偽
  値・`null` に解決されたキーは、JSON がそれを書くときのテキスト（`1`、`true`、
  `null`）として格納されます。非文字列キーを持つドキュメントも読み込めますが、
  書き出すとそれらのキーは引用されます。
- **日付・バイナリ・集合・順序付きマップの型はありません。** `!!timestamp`、
  `!!binary`、`!!set`、`!!omap`、アプリケーション独自タグは、ノードをデコードされた
  ままにします（たいていは文字列）。日付は書き出し時に引用されるので、出力を
  PyYAML で読み戻しても `datetime` オブジェクトにはなりません。
- **長い行は折り返しません。** PyYAML は 80 桁付近で行を折りますが、このエミッタ
  は各スカラーを 1 行で書きます。出力は妥当な YAML で、読み込み結果も同一です。
  ただ横に長いだけです。
- **`%YAML` と `%TAG` ディレクティブは未実装です。**
- ネストは `MAX_DEPTH`（1000）段までです。

それ以外はすべて `test/yaml/test_pyyaml_compat.mojo` が PyYAML と突き合わせて
検証します。これは PyYAML の実際の出力から生成されており、各ドキュメントが何に
読み込まれるかと、その値が何に書き戻されるかの両方を含みます。
