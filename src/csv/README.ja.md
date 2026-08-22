# `csv`

*[English](README.md) · 日本語*

純粋な Mojo による CSV のリーダとライタです。CPython の `_csv` と同じ状態機械を、
文字単位で、壊れた入力でしか現れない部分も含めてそのまま動かします。

```mojo
from csv import reader, writer
```

## 読み込み

```mojo
var rows = reader('name,city\n"Ada, L",London\n')

len(rows)              # 2
rows[1][0]             # "Ada, L"

for row in reader(text):
    print(row[0])
```

行は `List[String]` で、`reader` は全行を一度に返します。`load(file)` はファイル
全体を読んで同じことをします。

扱いの難しいケースは、簡略化したものではなく CPython のそのものです。

| 入力 | 読み込み結果 |
|------|-------------|
| `a"b,c` | `['a"b', 'c']` — フィールド先頭以外の引用符はデータ |
| `"ab"cd` | `['abcd']` — 閉じ引用符のあとのデータはフィールドにつながる |
| `"abc` | `['abc']` — 開いたままの引用符はテキスト末尾まで続く |
| `a,b\r1,2` | 2 行 — 単独の `CR` も `LF` や `CRLF` と同じくレコードを終える |
| `a,b\n\nc,d` | 3 行。真ん中は空行 |

`strict` では、壊れている 2 つ（`"ab"cd` と `"abc`）は代わりに送出します。文言は
CPython のものです。

```text
',' expected after '"'
unexpected end of data
```

## 書き出し

```mojo
var out = writer()
out.writerow(["a", "b"])
out.writerows(rows)
print(out.text())

writes(rows)                # 同じことを 1 回の呼び出しで
dump(rows, file)            # ライタへ直接
```

フィールドが引用されるのは、その文字自体が要求するときだけです。区切り文字、復帰、
改行、行終端子に含まれる文字、あるいは二重化される引用符です。*エスケープ*される
文字は引用を強制しません。だからエスケープ文字を含むフィールドは、エスケープされた
まま引用なしで出てきます。空フィールド 1 つだけの行は `""` と書かれます。引用なし
だと空行として読み戻されてしまうためです。

## ダイアレクト

CPython はフォーマットパラメータを緩いキーワードとして渡し、残りを名前付きダイア
レクトが埋めます。ここではそれらが 1 つの構造体のフィールドです。

```mojo
reader(text, Dialect(delimiter=";"))
reader(text, Dialect(quoting=QUOTE_NONE, escapechar="\\"))
writes(rows, unix())
```

既定は `excel()` で、`excel_tab()` と `unix()` が CPython の登録する残り 2 つです。
`Dialect` は `delimiter`、`quotechar`、`escapechar`、`doublequote`、
`skipinitialspace`、`lineterminator`、`quoting`、`strict`、`field_size_limit` を
取り、`quoting` には `QUOTE_MINIMAL`、`QUOTE_ALL`、`QUOTE_NONNUMERIC`、
`QUOTE_NONE` が使えます。区切り文字・引用符・エスケープには、`€` を含めどんな 1
文字でも使えます。

## レコード

`read_records` と `write_records` が `DictReader` と `DictWriter` にあたります。
レコードは `Value`（`json`、`yaml`、`toml` パッケージが共有する型）なので、メンバは
ヘッダの順序を保ち、CSV ファイルは変換なしにそれらのフォーマットへ渡れます。

```mojo
from json import dumps
from csv import read_records

print(dumps(read_records("a,b\n1,2\n")[0]))
# {"a": "1", "b": "2"}
```

短いレコードは `restval` で埋められ、長いレコードの余りは `restkey` の下に入り、
空行は空レコードにならず読み飛ばされます。レコードはメンバの型を保つので、
`QUOTE_NONNUMERIC` は数値を引用なしで書き、それ以外を引用します。`DictWriter` と
まったく同じ挙動です。

## CPython との違い

- **行はテキストです。** `QUOTE_NONNUMERIC` を使った `csv.reader` は行に `float`
  オブジェクトを入れますが、ここでの行は文字列を保持します。したがって数値は
  Python の `str` が書くとおりにそのまま描き戻され、`1` は `1.0` として読まれます。
  変換自体は Python の `float` そのもので、Unicode の十進数字や Unicode の空白も
  含みます（`１２` は 12 です）。数値でないフィールドはこれまでどおり
  `could not convert string to float: 'a'` を送出します。
- **`field_size_limit` はダイアレクトのフィールド**であり、プログラム全体で共有
  されるグローバルな `csv.field_size_limit()` ではありません。
- **長いレコードの余りのフィールドは捨てられます。** `restkey` が置き場所を指定
  しない限りそうなります。CPython は dict の `None` キーの下に入れますが、テキスト
  でキー付けされたオブジェクトにはその置き場所がありません。
- **`Sniffer` とダイアレクトのレジストリは未実装です。** `register_dialect` は
  ありません。`Dialect` を作って渡してください。
- **`quotechar=None` には `QUOTE_NONE` が必要です。** CPython は、呼び出しに
  `quoting` を書かない限りどの引用方式との組み合わせも受け入れ、`quoting` を明示的
  に渡した瞬間に拒否します。これはキーワードの読み方の副産物であり、ここに再現
  すべきものはありません。
- **リーダは行イテレータではなくテキストを取ります。** `newline=""` で開いた
  ストリームに対して Python が行うのとまったく同じように行を分割します。2 つが
  一致するのはそのためです。したがって、手製の行イテレータでしか引き起こせない
  唯一のエラー `new-line character seen in unquoted field` は到達不能です。

それ以外はすべて `test/csv/test_python_compat.mojo` が CPython と突き合わせて検証
します。これは `csv` が実際に生成するものから作られており、各ドキュメントが何に
読み込まれるかと、その行が何に書き戻されるかの両方を、15 種のダイアレクトと
およそ 1600 通りの組み合わせにわたって含みます。

## 性能

`bench/csv` のフィクスチャで、C で書かれている CPython 3.11 の `_csv` に対して:

| フィクスチャ | `reader` | `writer` |
|-------------|----------|----------|
| plain (0.47 MiB) | 9.22 ms 対 9.51 ms — **1.0 倍** | 7.72 ms 対 9.21 ms — **1.2 倍**速い |
| quoted (0.42 MiB) | 5.91 ms 対 5.59 ms — **0.9 倍** | 6.04 ms 対 7.22 ms — **1.2 倍**速い |

読み込みは C 実装と同等、書き出しは少し先行しています。双方 3 回の中央値を、他に
負荷のない 4 コア x86-64 Linux マシンで連続して取得しました。マシンが空いている
必要があります。混んだマシンでの目減りの仕方が両者で同じではないためです。

再現手順:

```bash
python3 bench/csv/gen_data.py
mojo run -I src bench/csv/bench_csv.mojo
python3 bench/csv/bench_python.py
```
