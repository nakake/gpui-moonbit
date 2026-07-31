# gpui-bindings 消費者向けガイド

Rust/GPUI を MoonBit native から C FFI 越しに呼び、ネイティブウィンドウを描画するための MoonBit モジュール（`nakake/gpui-bindings`）です。UI ツリー全体を 1 つの**コマンドバッファ**として記述し、`build_tree` 1 回の FFI 呼び出しで Rust 側にコミットします。クリック・キー・テキストイベントは Rust から MoonBit の固定 callback `app.dispatch` に戻り、フレームワーク層（型付きハンドラレジストリ・状態ストア・signal・コンポーネント、RFC 0001）がデコード・配送・再構築を担います。

このモジュールはローカル向けの実験的プロジェクトであり、安定した汎用 UI API ではありません。内部設計の詳細は [`docs/architecture.md`](../docs/architecture.md)（AI 向け内部文書）を参照してください。

## 必要条件

native build のみ対応です。対応 OS/architecture は macOS arm64・x86_64、Linux x86_64、Windows MSVC x64（cross compile 非対応）。

- Rust toolchain（`cargo`）と MoonBit native toolchain（`moon`）
- macOS: Xcode Command Line Tools / Xcode、macOS SDK、GPUI/Metal 用フレームワーク
- Linux: native C/C++ toolchain と X11/XKB 系ライブラリ。システムの XCB/XKB runtime library が使えない場合は、リポジトリ root の ignored な fallback `.linux-libs/` を利用できます
- Windows: Rust/MoonBit と MSVC x64 C++ build tools（`build.ps1` は `cl.exe` 未設定時に Visual Studio の x64 開発シェルを自動検出します）

## クイックスタート

このディレクトリ単独の `moon build` は完全な最終 build 手順ではありません。Rust static library、OS 別 link flags、Rust→MoonBit callback symbol はリポジトリ root の build driver が準備します。

```bash
git clone https://github.com/nakake/gpui-moonbit.git
cd gpui-moonbit

# macOS / Linux
./build.sh
```

```powershell
# Windows
.\build.ps1
```

build 完了後、build driver が起動コマンドを表示します。

```bash
# macOS（キーボード入力には .app バンドルが必要）
open dist/Counter.app
# stderr をターミナルで見る場合
./dist/Counter.app/Contents/MacOS/Counter

# Linux / WSLg（X11 経路を明示）
cd moonbit-bindings
env -u WAYLAND_DISPLAY \
  ./_build/native/debug/build/cmd/main/main.exe
# システムの XCB/XKB runtime library が見つからない場合だけ:
LD_LIBRARY_PATH=$PWD/../.linux-libs env -u WAYLAND_DISPLAY \
  ./_build/native/debug/build/cmd/main/main.exe
```

```powershell
# Windows
.\moonbit-bindings\_build\native\debug\build\cmd\main\main.exe
```

起動すると Counter デモが表示されます。`-1` / `Reset` / `+1` / `+10` ボタン、`j` / `k` / `r` キー、Enter/Escape/矢印キー、数字入力で値を操作できます。

MoonBit 側の型検査だけなら、このディレクトリで `moon check`（および `moon test`）を実行できます。

## 使い方

アプリの実装パターンは [`app/app.mbt`](app/app.mbt)（Counter）が手本です。低水準のコマンドバッファの上に、フレームワーク層（状態・ハンドラ・コンポーネント・イベントループ）を載せます。

### 1. ツリーをコマンドバッファで記述する

`CommandBuffer` はスタックマシンです。`div()` / `text()` はノードを生成してスタックに積み、setter はスタックトップに適用され、`add_child()` は子→親を接続して親をスタックトップに残し、`set_root()` でルートを確定します。

```moonbit nocheck
///|
pub fn build_tree(view : Int) -> Result[Unit, Int] {
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div() // ルート
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(28.0)
  cb.set_padding(32.0)

  cb.text("Counter", 236, 239, 245, 30.0)
  cb.add_child()

  // クリック可能なボタン: HandlerId は dispatch にルーティングされる
  cb.div()
  cb.set_key("btn-increment") // 安定した識別子（任意）
  cb.set_size(92.0, 56.0)
  cb.set_bg(70, 160, 95)
  cb.set_rounded(10.0)
  cb.set_flex_col()
  cb.set_center()
  cb.set_on_click(btn_increment.to_int()) // HandlerRegistry 発行の HandlerId
  cb.text("+1", 255, 255, 255, 18.0)
  cb.add_child() // ラベルをボタンに接続
  cb.add_child() // ボタンをルートに接続

  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}
```

利用可能なコマンド: `div` / `text` / `set_size` / `set_bg` / `set_flex_row` / `set_flex_col` / `set_center` / `set_gap` / `set_rounded` / `set_on_click` / `set_key` / `set_padding` / `set_border` / `add_child` / `set_root`。色成分は 0–255 にクランプされます。テキストは内部で UTF-8 にエンコードされ、明示長で送られます（NUL 終端なし）。繰り返し現れる部分木は**コンポーネント**（`button(cb, props)` など、`components.mbt`）として切り出せます。コンポーネントは `CommandBuffer` に部分木を書き、ルートはスタックに残るので、呼び出し側が `add_child()` で接続します。

### 2. ウィンドウを開く

```moonbit nocheck
match @nakake/gpui-bindings.run_window(0, 600.0, 500.0) {
  Ok(_) => ()
  Err(status) => abort("run_window failed with status \{status}")
}
```

`run_window(view, width, height)` は `view` にコミット済みのツリーを描画し、イベントループでブロックします。`view` は `build_tree` が設定する Rust 側 view slot の index です。`build_tree` / `run_window` は `Result[Unit, Int]` を返し、`Err(status)` の `status` は負の `GPUI_STATUS_*` コードです。

### 3. 状態・ハンドラ・イベントループ（フレームワーク層、RFC 0001）

状態とイベント配送はフレームワーク層が担います。ハンドラは「変わったか」を戻り値で報告せず、signal を `set` するだけ。再構築はフレームワークが store の dirty 判定でスケジュールします。

- **`Store` / `CellId[T]`**（`store.mbt`）: 型付き状態セル。`Store::new()` で作り、`new_cell(initial)` で `CellId[T]` を得ます。`get` / `set` で読み書きし、`cell_for_key(key, initial)` でキー付き共有セルも作れます。
- **`Signal[T]`**（`signal.mbt`）: セルを購読する宣言的プリミティブ。`store.signal(cell)` で作り、`sig.get(store)` / `sig.set(store, value)` で操作します。`set` が store を dirty にします。
- **`HandlerRegistry`**（`handlers.mbt`）: 型付きハンドラの登録と配送。`on_click(fn(view){…})` は `HandlerId` を返し、`on_key` / `on_named_key` / `on_text` も登録できます。`dispatch(event, view)` が `Event` を該当ハンドラへ fan-out します。
- **`RenderCtx`**（`components.mbt`）: `{ view, store, handlers }` を束ね、コンポーネントへ渡す描画コンテキスト。
- **`framework_dispatch`**（`framework.mbt`）: envelope デコード → ハンドラ配送 → dirty 判定 → 再構築を 1 本にまとめたイベントループ接着。

アプリの骨格:

```moonbit nocheck
let store = @nakake/gpui-bindings.Store::new()
let count = store.signal(store.new_cell(0))
let handlers = @nakake/gpui-bindings.HandlerRegistry::new()
let btn_increment = handlers.on_click(fn(_view) {
  count.set(store, count.get(store) + 1)
})
let ctx : @nakake/gpui-bindings.RenderCtx = { view: 0, store, handlers }

pub fn dispatch(version : Int, kind : Int, view : Int, data_a : Int, data_b : Int) -> Int {
  @nakake/gpui-bindings.framework_dispatch(ctx, version, kind, view, data_a, data_b, fn(v) {
    build_tree(v)
  })
}
```

### 4. イベントを受け取る（callback 契約）

Rust からのイベントは、パッケージ `app` の関数 `dispatch` に固定の 5×i32 envelope で届きます。これは ABI 契約であり、パッケージ名と関数名は変えません。実体は `framework_dispatch` への 1 行委譲です。

```moonbit nocheck
pub fn dispatch(version : Int, kind : Int, view : Int, data_a : Int, data_b : Int) -> Int
```

- slot 0 `version`: 常に `ABI_VERSION`（現在は `4`）。不一致なら `framework_dispatch` がハンドラを実行せず `0` を返して古い Rust バイナリを拒否します
- slot 1 `kind`: イベント種別（`EVENT_CLICK` = 1、`EVENT_KEY` = 2、`EVENT_TEXT` = 3、`EVENT_NAMED_KEY` = 4）
- slot 2 `view`: 再構築対象の view id
- slot 3–4 `data_a` / `data_b`: 種別依存
  - `EVENT_CLICK`: `data_a` = click_id（`HandlerId` の raw 値）、`data_b` = 0
  - `EVENT_KEY`: `data_a` = codepoint、`data_b` = modifier bits
  - `EVENT_TEXT`: `data_a` = token、`data_b` = byte 長（ペイロードは `gpui_event_copy_text` でコピー）
  - `EVENT_NAMED_KEY`: `data_a` = named_key id（`KEY_ENTER` / `KEY_ESCAPE` / `KEY_UP` …）、`data_b` = modifier bits

`dispatch` は状態が変わった場合に `1`、変わらない場合に `0` を返します。`framework_dispatch` は配送の前後で store の dirty を区切り、`set` が 1 度でも起きたときだけ再構築コールバックを呼んで `1` を返します。`1` のときだけ Rust 側が再描画通知（`cx.notify()`）を行います。再構築に失敗しても Rust 側は旧ツリーを保持しているため、dirty に基づき `1` を返して構いません。

MoonBit native の `Int` は 32-bit であり、この callback とコマンドバッファの境界も **i32** です（`gpui_abi_probe` で機械検証済み）。値は i32 範囲で扱ってください。

`main` 関数では、dead-code elimination が `dispatch` を消さないよう明示的に保持します（[`cmd/main/main.mbt`](cmd/main/main.mbt) を参照）。

## Examples

- [`app/app.mbt`](app/app.mbt) — interactive Counter（ボタン 4 つ + キー操作 + テキスト入力）。`cmd/main` から起動する現行デモです。
- [`examples/hello/`](examples/hello/) — Counter 以外の最小例。静的なタイトルと ON/OFF が切り替わるステータスカード、1 つのトグルボタン、`space` / `Escape` キー操作を実装しています。

`examples/hello` は `app/` と同じく**ライブラリパッケージ**です。`moon check` / `moon build` で型検査・コンパイルされ、API 変更に対して常に追従します。実行可能ファイルの生成には Rust staticlib とのリンクが必要で、それは root の build driver が `cmd/main` 向けにだけ準備するため、現状はコード例としての提供です。実行可能にするには、`cmd/main` と同じ OS 別 link template 方式で `cmd/hello` エントリを追加し build driver に組み込む作業が別途必要です（将来の作業）。`hello.mbt` の `launch()` が、その際の実行ファイルから呼ぶエントリポイントです。

## API リファレンス

公開 API（`CommandBuffer` の各メソッド、`build_tree` / `run_window`、フレームワーク層の `Store` / `CellId` / `Signal` / `HandlerRegistry` / `HandlerId` / `RenderCtx` / `button` / `framework_dispatch`、`Event`、および `abi_constants.mbt` の定数群）には MoonBit の doc comment `///|` が付いています。ソースと併せて参照してください。

- 対象ファイル: [`gpui-bindings.mbt`](gpui-bindings.mbt)（高水準 API）、[`components.mbt`](components.mbt) / [`store.mbt`](store.mbt) / [`signal.mbt`](signal.mbt) / [`event.mbt`](event.mbt) / [`handlers.mbt`](handlers.mbt) / [`framework.mbt`](framework.mbt)（フレームワーク層、RFC 0001）、[`abi_constants.mbt`](abi_constants.mbt)（`gpui-sys/abi.toml` から生成される ABI 定数）
- ドキュメント生成: MoonBit ツールチェーンの標準手段は `moon doc`（`moon doc --serve` でローカルサーバ起動）です。現行ツールチェーン（moon 0.1.20260721 時点）では、パッケージ単位の JSON（`_build/doc/nakake/gpui-bindings/package_data.json` 等、`///|` doc comment を含む）は生成されますが、最終的なドキュメントサイト組み立て段階で moondoc が `moon.mod.json` を要求して例外終了します（本モジュールは新形式の `moon.mod` を使用）。サイト生成は moondoc 側の対応待ちです。それまでは `///|` doc comment とソースが API リファレンスの正本です。

## 制約・注意

- **native バックエンド専用**です。wasm 等の他 target には対応しません。
- **callback は単一固定契約**です。Rust→MoonBit のイベント経路は `app.dispatch(version, kind, view, data_a, data_b) -> Int`（5×i32 envelope、`ABI_VERSION` = 4）の 1 本だけです。実体は `framework_dispatch` への委譲で、デコード・型付き配送・dirty 判定・再構築をフレームワーク層が担います。パッケージ `app` と関数 `dispatch` を改名するとマングルシンボルが変わり、Rust 側と build driver の両方の更新が必要になります。
- **境界の整数は i32** です。MoonBit native の `Int` は 32-bit 2 の補数機械語であり、FFI 境界とコマンドバッファの wire format は i32/u32 little-endian です。この ABI 互換は `gpui_abi_probe` の境界値往復（ビルドのたびに実行）と wbtest で機械検証されています。
- **ツリー更新は dirty 時の再構築**です。状態変化（signal の `set`）のたびにフレームワークがツリーを再構築します。Counter は `update_text` でカウント表示だけを書き換えるインクリメンタル経路を試し、キー未登録時は `build_tree` による全再構築へフォールバックします（issue #10）。汎用 vdom diff は意図的に未実装です。
- **opcode と ABI 定数は生成物**です。`gpui-sys/abi.toml` を正本として build driver が生成します。`abi_constants.mbt` と `gpui-bindings-ffi.mbt` は手編集しません。
- 負の status code の意味（無効 handle、バッファの magic/バージョン不一致、未知 opcode、ルート未指定、キー重複など）は [`docs/architecture.md`](../docs/architecture.md) を参照してください。
- **callback はメインスレッド限定・total 関数**です。ランタイムは非アトミック参照カウントのため、`dispatch` はメインスレッドからのみ呼べます。MoonBit の panic は FFI 境界を越えられず process abort になるため、callback は例外を投げない全関数に保ってください。詳細は [`docs/architecture.md`](../docs/architecture.md) §11「MoonBit native 実行時制約」を参照。
- **エラーは構造化できます**。`build_tree` / `run_window` の `Err(status)` は、`classify_status(status)` で `GpuiError` に変換でき、`status_message(status)` / `GpuiError::to_string` で 1 行の診断メッセージを得られます。回復できない失敗には `expect_ok(result, ctx)` が構造化メッセージ付きで abort します。

## ライセンス

Apache-2.0
