# `json`

*[English](README.md) · 日本語*

純粋な Mojo による JSON のデコーダ、エンコーダ、ドキュメントモデルです。CPython
の `json` モジュールに合わせて作られており、関数名もキーワード引数も、出力される
バイト列も、エラーメッセージも同じです。

```mojo
from json import JSONType, JSONValue, dump, dumps, load, loads
```

## デコード

```mojo
var doc = loads('{"id": 7, "tags": ["a", "b"], "meta": null}')

doc["id"].int()            # 7
doc["tags"][0].string()    # "a"
doc["meta"].is_null()      # True
len(doc)                   # 3
"tags" in doc              # True
```

`loads(text, *, strict=True, allow_nan=True)` は、CPython のものが `str` または
`bytes` を取るのと同じように、`StringSlice` または UTF-8 バイト列を取ります。
`load(file, ...)` はまず `FileHandle` を読みます。

失敗すると `JSONDecodeError` を送出します。メッセージは位置に至るまで CPython の
ものと同じです。

```text
Expecting ',' delimiter: line 1 column 8 (char 7)
```

## エンコード

```mojo
dumps(doc)                              # {"id": 7, "tags": ["a", "b"], "meta": null}
dumps(doc, indent=2)                    # 整形。1 段あたり空白 2 個
dumps(doc, indent="\t")                 # 整形。1 段あたりタブ 1 個
dumps(doc, separators=(",", ":"))       # 詰めて出力
dumps(doc, sort_keys=True)              # メンバをコードポイント順に
dumps(doc, ensure_ascii=False)          # UTF-8 をそのまま出す
dumps(doc, allow_nan=False)             # NaN を書かずに送出する
```

既定値は CPython のものなので、指定しない限り `dumps` は `,` と `:` のあとに空白
を入れます。`dump(value, file, ...)` は `FileHandle` でも `String` でも、任意の
`Writer` に、ドキュメント全体をバッファせずに書き込みます。`String(value)` と
`print(value)` は既定のオプションを使います。

## ドキュメントの構築

```mojo
var doc = JSONValue.object()
doc["name"] = "mojo"
doc["scores"] = JSONValue.array()
for i in range(3):
    doc["scores"].append(i * i)
```

`append` と `__setitem__` は `Int`、`Float64`、`Bool`、`StringSlice`、`None`、
`JSONValue` を取ります。配列は `append`、`extend`、`pop`、`clear`、負のインデックス、
要素代入に対応し、オブジェクトは `get`、`keys`、`values`、`items`、`update`、
`setdefault`、`pop`、`clear`、`in` に対応します。

反復は Python に従い、配列は要素を、オブジェクトはキーを返します。

```mojo
for tag in doc["tags"]:
    print(tag.string())

for key in doc:
    print(key.string(), "=", doc[key.string()])
```

## 値のセマンティクス

`JSONValue` は共有ドキュメントへの参照カウント付きハンドルです。したがって
`doc["a"]` は、Python の `dict` や `list` とまったく同じように `doc` を別名参照
します。

```mojo
var tags = doc["tags"]
tags.append("new")
len(doc["tags"])      # "new" を含む
```

Python と唯一違うのは、*別の*ドキュメントに属する値を挿入するとディープコピーに
なる点です。1 つの値が 2 つのアリーナにまたがれないためです。同じドキュメントの
値を挿入した場合は、Python と同じく別名参照になります。

`__eq__` は構造的に比較し、数値は `int` と `float` をまたいで比較され
（Python と同じく `1 == 1.0`）、オブジェクトの比較はメンバ順を無視します。

## 設定の再利用

`JSONEncoder` と `JSONDecoder` は設定を保持し、呼び出しごとではなく一度だけ解決
します。CPython の同名クラスに対応します。

```mojo
var encoder = JSONEncoder(indent=2, sort_keys=True)
for doc in documents:
    print(encoder.encode(doc))

var decoder = JSONDecoder(strict=False)
var parsed = decoder.decode(text)
```

`encoder.write_into(writer, value)` は `String` を返す代わりにストリーム出力します。

`decoder.raw_decode(text, idx)` は値を 1 つデコードし、どこで終わったかを返します。
1 つのバッファに連結されたドキュメントを読むときはこれを使います。

```mojo
var text = String('{"a":1}{"b":2}')
var first, after = JSONDecoder().raw_decode(text)
var second, _ = JSONDecoder().raw_decode(text, after)
```

CPython のものと同じく、値の前の空白は読み飛ばさず、後ろの空白も消費しません。

## フック

`parse_int`、`parse_float`、`parse_constant`、`object_hook` はここにもありますが、
実行時のコーラブルではなくコンパイル時の型パラメータです。Mojo は関数を
`Optional` に入れられないためです。フックは `NumberHook` または `ValueHook` を
実装した型です。

```mojo
from json import JSONValue, NumberHook, loads


struct KeepLiteral(NumberHook):
    @staticmethod
    def call(text: String) raises -> JSONValue:
        return JSONValue(text)


# 64 ビットを超える整数は通常 float に広がるが、これなら正確なまま保てる。
var doc = loads[ParseInt=KeepLiteral]("123456789012345678901234567890")
```

`ObjectHook` は `ValueHook` で、各オブジェクトが完成するたびに内側から順に
呼ばれ、自由に保持・変更できる独立したドキュメントを受け取ります。フックを既定の
ままにしておくコストはゼロです。デコーダはコンパイル時に型で分岐するので、使わ
れない経路は生成されません。

## 型の判定

`value.type()` は `JSONType` を返します。`NULL`、`BOOL`、`INT`、`FLOAT`、
`STRING`、`ARRAY`、`OBJECT` のいずれかで、対応する Python の型名として表示され
ます。`is_null`、`is_bool`、`is_int`、`is_float`、`is_number`、`is_string`、
`is_array`、`is_object`、`is_container` の述語も同じ範囲をカバーします。

ドキュメントが往復できるよう、`INT` と `FLOAT` は区別されたままです。`loads("1")`
は int、`loads("1.0")` は float で、`dumps` はそれぞれ元の書き方で書き戻します。
Python と違い `True` が int として報告されることはないので、`dumps` は 2 つの
リテラルを区別できます。

## CPython との違い

意図的な相違が 3 つあり、いずれも Mojo の型に由来します。

- **64 ビットを超える整数は float になります。** CPython は任意精度整数で正確に
  保ちますが、ここにそのような型はありません。
- **対になっていないサロゲートのエスケープは U+FFFD にデコードされます。**
  CPython は `str` に単独のサロゲートを保持できますが、Mojo の文字列は厳密に
  UTF-8 なので、`"\ud800"` は置換文字になります。
- **有効数字が 19 桁を超える数値は丸めが異なることがあります。** 変換前に 19 桁の
  仮数と指数へ正規化されます。これは `Float64` が区別して表現できるすべての値に
  対して正確ですが（17 桁で足ります）、それより長いリテラルでは最終桁が 1 単位
  ずれることがあります。

最初の 2 つには逃げ道があります。リテラルを文字列として返す `ParseInt` または
`ParseFloat` フックを使えばどんな値も正確に保てますし、`ParseConstant` で受け入れ
たくないものを拒否できます。

CPython の引数のうち 3 つは、ここでは意味を持ち得ないため存在しません。
`skipkeys` は文字列でも数値でもない dict のキーを飛ばしますが、JSON オブジェクトの
キーは常に文字列です。`default` はシリアライズできないオブジェクトの代替を与え
ますが、`JSONValue` が保持できる値はすべて既にシリアライズ可能です。
`object_pairs_hook` が CPython にあるのは主にメンバ順の保持と重複キーの検出のため
ですが、どちらもこのライブラリが自前で行っています。

## 制限

コンテナのネストは `MAX_DEPTH`（1000）段までです。パーサは反復的なのでもっと深く
まで行けますが、`dumps`、構造的等価判定、ドキュメント間のコピーはいずれも再帰的に
ドキュメントを辿るため、それより深いとマシンスタックが溢れます。CPython も同程度
の深さで `RecursionError` を出して諦めます。

この上限は循環検出も兼ねます。値はドキュメント内で互いを別名参照できるため、自身の
部分木に差し込まれた値は到達可能になります。

```mojo
var doc = JSONValue.object()
doc["self"] = doc
_ = dumps(doc)     # 送出: Circular reference detected, or nesting deeper...
```

それ以外はすべて `test/json/test_python_compat.mojo` が CPython と突き合わせて
検証します。これは手書きではなく、CPython の実際の出力から生成されています。
