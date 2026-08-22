# encoding-mojo

*[English](README.md) · 日本語*

Mojo 向けのデータフォーマット・エンコーダ／デコーダ集です。すべて純粋な Mojo で
書かれており、API は Python 互換です。Mojo の標準ライブラリはこれらをまったく
提供していないため、各パッケージは既に馴染みのある Python モジュールを写して
います。`json` は CPython の `json`、`yaml` は PyYAML の
`safe_load`／`safe_dump`、`toml` は `tomllib` と `tomli_w`、`csv` は CPython の
`csv` に対応します。

```mojo
from json import dumps, loads

var doc = loads('{"name": "mojo", "tags": ["fast", "safe"]}')
print(doc["name"].string())        # mojo
print(len(doc["tags"]))            # 2

doc["tags"].append("pure")
print(dumps(doc, indent=2))
```

すべてのパッケージが 1 つのドキュメントモデルを共有しているため、値は変換なしに
フォーマットをまたげます。

```mojo
from csv import read_records
from json import dumps
from toml import loads as toml_loads
from yaml import safe_load

print(dumps(safe_load("name: mojo\ntags: [fast, safe]\n")))
# {"name": "mojo", "tags": ["fast", "safe"]}

print(dumps(toml_loads('name = "mojo"\ntags = ["fast", "safe"]\n')))
# {"name": "mojo", "tags": ["fast", "safe"]}

print(dumps(read_records("name,tags\nmojo,fast\n")[0]))
# {"name": "mojo", "tags": "fast"}
```

## パッケージ

| パッケージ | 状態 | 内容 |
|-----------|------|------|
| [`json`](src/json) | 完成 | デコーダ、エンコーダ、フック、可変ドキュメントモデル。CPython の `json` と突き合わせ済み |
| [`yaml`](src/yaml) | 完成 | PyYAML が実装する YAML 1.1 のローダとエミッタ。PyYAML と突き合わせ済み |
| [`toml`](src/toml) | 完成 | TOML 1.0.0 のパーサとライタ。`tomllib` と `tomli_w` に突き合わせ済み |
| [`csv`](src/csv) | 完成 | CPython 自身の `_csv` 状態機械をそのまま動かすリーダとライタ |
| [`serde`](src/serde) | 完成 | すべてのパッケージが土台にする `Value` 型とテープ |

## ドキュメント

各パッケージには、API 全体を実行可能な例つきで解説した手書きのガイドが英語と
日本語で用意されています。

| パッケージ | Guide | ガイド |
|-----------|-------|--------|
| `json` | [src/json/README.md](src/json/README.md) | [日本語](src/json/README.ja.md) |
| `yaml` | [src/yaml/README.md](src/yaml/README.md) | [日本語](src/yaml/README.ja.md) |
| `toml` | [src/toml/README.md](src/toml/README.md) | [日本語](src/toml/README.ja.md) |
| `csv` | [src/csv/README.md](src/csv/README.md) | [日本語](src/csv/README.ja.md) |
| `serde` | [src/serde/README.md](src/serde/README.md) | [日本語](src/serde/README.ja.md) |

ガイド中の例は実行されます。`test/json/test_readme_examples.mojo` と、
`yaml`・`toml`・`csv` の対応するファイルが、読者がコピーしうるスニペットを
すべて実行するので、コードから乖離したガイドはビルドを失敗させます。

これに加えて、`src/` の docstring から API リファレンス全体が生成されます。
シグネチャ、引数、戻り値、送出されるエラーがすべて含まれます。

```bash
./scripts/build_docs.sh               # docs/api/*.md を書き出す
./scripts/build_docs.sh --check       # docstring の検証だけを行う
```

`mojo doc` が docstring を JSON にまとめ、`scripts/render_api_docs.py` がそれを
Markdown に整形します。したがってリファレンスがソースから乖離することはありま
せん。`docs/api/` は生成物なのでコミットしていません。CI が push のたびに再生成
し、成果物としてアップロードします。

`scripts/check_docstrings.py` は同じ検査のコンパイラ不要版です。Python だけで
動き、公開宣言に docstring がない、`Args:` や `Parameters:` の項目が欠けている、
`Returns:` や `Raises:` がない、といった場合に失敗します。

## 速さの理由

パースされたドキュメントは、個別に確保されたノードの木ではありません。すべての
値は固定サイズノードからなる 1 つの平坦なアリーナ（"テープ"）に置かれ、それに
子インデックスの配列 1 本とデコード済み文字列バイトのバッファ 1 本が付きます。
値が `n` 個のドキュメントの確保回数は `O(n)` ではなく `O(1)` で、`Value` は
そのアリーナを指す 12 バイトの参照カウント付きハンドルです。

さらに、文字列はSIMD で 32 バイトずつ走査され、エスケープを含まなければ 1 回の
`memcpy` でコピーされます。数値は同じ走査の途中で仮数を積み上げ、最後に 1 回の
正確に丸められた乗算で仕上げます。メンバが 16 個を超えたオブジェクトにはハッシュ
索引が付くので、参照が線形走査に落ちることはありません。

`bench/json` のフィクスチャで、CPython 3.11 の C 実装つき `json` と比較した結果
（5 回の中央値、4 コア x86-64 Linux）:

| フィクスチャ | 形状 | `loads` | `dumps` |
|-------------|------|---------|---------|
| twitter (0.47 MiB) | 文字列が多い | **1.5 倍**速い | **2.1 倍**速い |
| canada (0.73 MiB) | 浮動小数点が多い | **3.2 倍**速い | **2.0 倍**速い |
| catalog (0.93 MiB) | オブジェクトが多い | **2.1 倍**速い | **3.0 倍**速い |

`bench/yaml` のフィクスチャで PyYAML と比較した結果:

| フィクスチャ | `safe_load` | `safe_dump` |
|-------------|-------------|-------------|
| config (0.20 MiB) | **61 倍**速い | **127 倍**速い |
| records (0.27 MiB) | **57 倍**速い | **128 倍**速い |

`bench/toml` のフィクスチャで CPython の `tomllib` と `tomli_w` に対して:

| フィクスチャ | `loads` | `dumps` |
|-------------|---------|---------|
| config (0.20 MiB) | **6.1 倍**速い | **10.0 倍**速い |
| records (0.33 MiB) | **6.5 倍**速い | **10.0 倍**速い |

`bench/csv` のフィクスチャで、上の 2 つと違って C で書かれている CPython の `csv`
に対して:

| フィクスチャ | `reader` | `writer` |
|-------------|----------|----------|
| plain (0.47 MiB) | **1.0 倍** | **1.2 倍**速い |
| quoted (0.42 MiB) | **0.9 倍** | **1.2 倍**速い |

YAML の数値は、ここに入っている PyYAML の純 Python バックエンドに対するもので
す。PyYAML には libyaml を使うオプションの C バックエンド（`CSafeLoader`）も
あり、それが使える環境では差はずっと小さくなります。ベンチマークスクリプトは
可能なら C バックエンドを使い、どちらで動いたかを表示します。

再現手順:

```bash
python3 bench/json/gen_data.py       # フィクスチャを一度だけ生成する
mojo run -I src bench/json/bench_json.mojo
python3 bench/json/bench_python.py   # CPython 側の同じ表

python3 bench/yaml/gen_data.py
mojo run -I src bench/yaml/bench_yaml.mojo
python3 bench/yaml/bench_python.py

python3 bench/toml/gen_data.py
mojo run -I src bench/toml/bench_toml.mojo
python3 bench/toml/bench_python.py

python3 bench/csv/gen_data.py
mojo run -I src bench/csv/bench_csv.mojo
python3 bench/csv/bench_python.py
```

## インストール

パッケージはただの Mojo ソースです。コンパイラに `src` を指すか、

```bash
mojo run -I /path/to/encoding-mojo/src your_program.mojo
```

事前コンパイルしてパッケージファイルに依存させます。

```bash
./scripts/build_packages.sh          # build/json.mojoc などを書き出す
mojo run -I build your_program.mojo
```

Mojo コンパイラ（`pip install modular`）が必要です。Mojo 1.0 で開発しています。

## リポジトリ構成

```
src/serde/           共有される Value 型と、その平坦なアリーナ
src/json/            json パッケージ
src/yaml/            yaml パッケージ
src/toml/            toml パッケージ
src/csv/             csv パッケージ
test/<name>/         各パッケージのテスト。領域ごとに 1 モジュール
bench/<name>/        各パッケージのベンチマークと Python 側の基準
docs/api/            生成された API リファレンス（コミットしない）
scripts/             テスト実行、パッケージビルド、ドキュメント生成、互換ケース生成
```

新しいフォーマットのパッケージも同じ形にします。`__init__.mojo` を持つ
`src/<name>/`、`test/<name>/test_*.mojo`、測る価値があれば `bench/<name>/` です。
`scripts/run_tests.sh`、`scripts/build_packages.sh`、`scripts/build_docs.sh` は
変更なしでそれを拾います。

## 開発

このライブラリはテストを先に書いて作られており、テストが仕様です。すべて実行
するには:

```bash
./scripts/run_tests.sh               # 個別のファイルを渡してもよい
```

`*_compat.mojo` のスイートは手書きではなく生成物です。下のスクリプトが数千件の
ドキュメントを CPython の `json` と `csv`、PyYAML、`tomllib`／`tomli_w` に通し、
その結果を記録します。つまり各スイートは、誰かの仕様解釈ではなく参照実装そのもの
に対する差分テストです。ケースを足すときは生成されたファイルではなくジェネレータ
の側に足してください。

```bash
python3 scripts/gen_compat_cases.py
python3 scripts/gen_yaml_compat_cases.py
python3 scripts/gen_toml_compat_cases.py
python3 scripts/gen_csv_compat_cases.py
```

ジェネレータには `pyyaml` と `tomli_w` が必要です。

ドキュメントもビルドの一部です。変更を送る前に次を実行してください。

```bash
python3 scripts/check_docstrings.py src   # コンパイラ不要
./scripts/build_docs.sh                   # mojo doc を含む完全な検査
```

新しい公開宣言には、要約と、すべての引数・パラメータの項目、該当する場合の
`Returns:`／`Raises:` を備えた docstring が必要です。パッケージの README の内容
を変える変更を入れたときは、隣にある日本語 README も更新し、例が動き続けるよう
`test/<name>/test_readme_examples.mojo` も更新してください。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
