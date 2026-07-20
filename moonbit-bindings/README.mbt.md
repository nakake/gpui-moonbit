# username/gpui-bindings

Rust/GPUI を MoonBit native から呼ぶための、ローカルかつ実験的な native-only モジュールです。安定した汎用 bindings ではありません。現在のアプリは [`app/app.mbt`](app/app.mbt) の interactive Counter で、`-1` / `Reset` / `+1` / `+10` と `j` / `k` / `r` を実装しています。

## 使い方

このディレクトリ単独の `moon build` は完全な最終 build 手順ではありません。Rust static library、OS 別 link flags、Rust から MoonBit への callback symbol を root の build driver が準備するため、リポジトリ root から OS に応じて実行してください。

```bash
# macOS / Linux
./build.sh
```

```powershell
# Windows
.\build.ps1
```

`build.sh` / `build.ps1` は platform/toolchain preflight、ABI 定数と FFI 宣言の生成、`moon check`、callback symbol と `int32_t` 戻り値 + 4 × `int32_t` 引数の検証、Cargo 由来 native link flags の投入、強制再リンク、OS 別の callback 最終検証を行います。macOS/Linux は `moon.pkg.macos` / `moon.pkg.linux`、Windows は `moon.pkg.windows` から `cmd/main/moon.pkg` を作成します。

## API と生成物

- `gpui-bindings.mbt` は手編集する高水準 API です。`create_div`、style setter、`create_text`、`add_child`、`reset`、`run_window`、`set_on_click` を提供します。
- `gpui-bindings-ffi.mbt` は `gpui-sys/include/gpui_sys.h` から `bindgen-moonbit` が生成する低水準 C FFI 宣言です。手編集しません。
- `abi_constants.mbt` は `gpui-sys/abi.toml` から build driver が生成します。ABI 定数は `abi.toml` を変更します。
- `app/app.mbt` は Counter の状態、イベント routing、tree 再構築を担います。Rust からの callback は固定の `app.dispatch(kind, id, a, b) -> Int` で、状態変更時に `1`、no-op 時に `0` を返します。tree 再構築と Rust の再描画通知は `1` の場合だけです。

`create_text(String, ...)` は `@utf8.encode` で String を UTF-8 `Bytes` に変換します。低水準 FFI は `#borrow(ptr)` の `Bytes` と明示的な長さを Rust の `const uint8_t *ptr, int32_t len` に渡すため、NUL 終端は使いません。

現在の高水準 API は C export の status を返しません。setter、`reset`、`run_window` の status は `ignore` されます。

## MoonBit の検証

```bash
moon check
moon test
```

これらはこのモジュールの型検査と限定的な MoonBit 単体テストです。Rust build、FFI 再生成、callback/ABI/link の統合検証には root の build driver を使います。
