# `toml`

*[English](README.md) · 日本語*

純粋な Mojo による TOML 1.0.0 のパーサとライタです。参照実装である Python の実装に
合わせて作られており、`loads`／`load` は CPython の `tomllib` に、`dumps`／`dump`
は [`tomli_w`](https://pypi.org/project/tomli-w/) に、出力バイト列まで従います。

```mojo
from toml import dumps, loads
```

ドキュメントは [`json`](../json) と [`yaml`](../yaml) パッケージが使うのと同じ
`Value` 型に読み込まれるため、TOML ドキュメントを変換なしに JSON として書き出せ
ます。

```mojo
from json import dumps as json_dumps
from toml import loads

print(json_dumps(loads('name = "mojo"\ntags = ["fast", "safe"]\n')))
# {"name": "mojo", "tags": ["fast", "safe"]}
```

## 読み込み

```mojo
var doc = loads("""
title = "example"

[owner]
name = "Tom"
dob = 1979-05-27

[servers.alpha]
ip = "10.0.0.1"
ports = [8001, 8002]
""")

doc["title"].string()               # "example"
doc["owner"]["name"].string()       # "Tom"
doc["servers"]["alpha"]["ports"][0].int()   # 8001
```

`load(file)` はファイル全体を読んでデコードします。

対応しているもの: ベアキー・引用キー・ドット付きキー、基本文字列・リテラル文字列・
両方の複数行形式（TOML が定義するすべてのエスケープを含む）、`_` 区切りを使える
10 進・16 進・8 進・2 進の整数、`inf` と `nan` を含む浮動小数点数、真偽値、配列、
インラインテーブル、`[table]` ヘッダ、`[[array of table]]` ヘッダ、コメント、
CRLF 改行。

TOML を厳格にしている規則も強制されます。キーは二重に定義できない、`[table]` は
二重宣言できず、ドット付きキーが既に構築したあとにも宣言できない、テーブルでない
値をテーブルとして開き直せない、`[header]` が名付けたテーブルを後のドット付きキー
で作り直せない、インラインテーブルは決して拡張できない（同じ波括弧内の後続のドット
付きキーからも）、静的に定義された配列には決して追加できない。制御文字が文字列に
入るのはエスケープ経由だけで、エスケープは Unicode スカラー値を指さねばならず、
行は `LF` または `CRLF` で終わり、復帰単独で終わることはありません。

失敗すると `TOMLDecodeError` を送出し、`tomllib` と同じ形で問題と位置を示します。

```text
Cannot overwrite a value (at line 2, column 6)
```

## 書き出し

```mojo
dumps(doc)                             # tomli_w の既定値
dumps(doc, indent=2)                   # 配列を狭く
dumps(doc, multiline_strings=True)     # 改行を含む文字列に """ ... """
dump(doc, file)                        # ライタへ直接
```

出力は `tomli_w` のものです。メンバはソートされず挿入順を保ち、テーブルのスカラー
キーはその `[sub.table]` セクションより前に来て、空の親テーブルは子のヘッダに畳ま
れ、配列は常に複数行に広げられて末尾カンマが付き、テーブルの配列はインライン
テーブルの配列として書かれます。ただしそのうち 1 つでも 100 文字を超えるか改行を
含む場合は `[[name]]` セクションになります。

`dumps` に渡すドキュメントはテーブルでなければならず、それ以外は送出します。

## `tomllib` との違い

- **日付・時刻の型はありません。** `tomllib` は `datetime`、`date`、`time` オブ
  ジェクトを返しますが、`Value` にそのような型はないため、`dob = 1979-05-27` は
  リテラルの綴りを保ったまま文字列 `"1979-05-27"` として読み込まれます。リテラル
  自体は構文とカレンダー上の日付の両方が完全に検査されるので、`2023-02-30` や
  `12:99:99` は拒否されます。書き出しでは引用された文字列として書き戻されるため、
  このパッケージを往復すると日付は文字列になります。
- **整数は 64 ビットです。** TOML は最低でも符号付き 64 ビットの範囲を要求します。
  その範囲外のリテラルは昇格されずに拒否されます。`tomllib` は任意精度の `int` を
  返します。
- **`loads` はバイト列ではなくテキストを取ります。** `tomllib.load` は自身で UTF-8
  をデコードするためバイナリファイルを読みますが、ここではまずテキストとして読み
  ます。
- ネストは `MAX_DEPTH`（1000）段までです。

それ以外はすべて `test/toml/test_tomllib_compat.mojo` が参照実装と突き合わせて
検証します。これは `tomllib` と `tomli_w` が実際に生成するものから作られており、
各ドキュメントが何に読み込まれるかと、その値が何に書き戻されるかの両方を含みます。

## 性能

`bench/toml` のフィクスチャで、CPython 3.11 の `tomllib`（純 Python のパーサ）と
`tomli_w` に対して:

| フィクスチャ | `loads` | `dumps` |
|-------------|---------|---------|
| config (0.20 MiB) | **6.1 倍**速い | **10.0 倍**速い |
| records (0.33 MiB) | **6.5 倍**速い | **10.0 倍**速い |

双方 3 回の中央値を、1 台の 4 コア x86-64 Linux マシンで連続して取得しました。
時間も比も厳密には環境をまたいで持ち運べません（同じ測定をより速いマシンで行うと
読み込みは 6.8〜7.6 倍でした）。定数ではなく差の傾向として見てください。

再現手順:

```bash
python3 bench/toml/gen_data.py
mojo run -I src bench/toml/bench_toml.mojo
python3 bench/toml/bench_python.py
```
