# GPUI + MoonBit

MoonBit native から Rust/GPUI を C FFI 越しに呼ぶ、ローカル向けの実験的プロジェクトです。安定した汎用 UI API ではありません。現在のデモは interactive Counter で、`-1` / `Reset` / `+1` / `+10` のボタン、ならびに `j` / `k` / `r` キーで値を操作します。

## プロジェクト構造

```text
.
├── gpui-sys/                         # Rust の staticlib と C ABI
│   ├── abi.toml                       # ABI 定数の手編集する正本
│   ├── src/lib.rs                     # ノード保持、描画、イベント、C export
│   ├── include/gpui_sys.h             # cbindgen による tracked な生成ヘッダー
│   └── mb_symbol.txt                  # build driver がローカル生成（ignored）
├── bindgen-moonbit/                   # C ヘッダーから MoonBit FFI 宣言を生成
├── moonbit-bindings/                  # native 専用 MoonBit モジュール
│   ├── gpui-bindings.mbt              # 手編集する高水準 API
│   ├── gpui-bindings-ffi.mbt          # bindgen による tracked な生成 FFI
│   ├── abi_constants.mbt              # abi.toml からの tracked な生成定数
│   └── app/app.mbt                    # Counter の状態・イベント・UI 構築
├── build.sh                           # macOS / Linux 用 build driver
├── build.ps1                          # Windows 用 build driver
├── bundle.sh                          # macOS Counter.app の作成
└── docs/architecture.md               # 現行実装の詳細
```

`moonbit-bindings/cmd/main/moon.pkg` は OS 別の `moon.pkg.macos` /
`moon.pkg.linux` /
`moon.pkg.windows` テンプレートから build driver が作る ignored なローカルファイルです。`_build/`、`target/`、`dist/` もローカル生成物です。`.linux-libs/` は、システムにない Linux runtime library を手動で展開する場合の ignored な fallback です。C ABI を変えた場合は、正本を更新して root の build driver を実行し、生成済みの tracked ファイルを確認してください。生成物を手編集しません。

## 必要条件

このリポジトリが扱うのは native build のみです。対応する OS / architecture は macOS arm64・x86_64、Linux x86_64、Windows MSVC x64 です。cross compile はサポート対象外です。

- Rust と MoonBit native toolchain
- macOS: Xcode Command Line Tools / Xcode、macOS SDK、GPUI/Metal 用フレームワーク
- Linux: native C/C++ toolchain と X11/XKB 系ライブラリ。システムの XCB/XKB runtime library が使えない場合は、ignored なローカル fallback `.linux-libs/` を利用できます
- Windows: Rust/MoonBit と MSVC x64 C++ build tools。`build.ps1` は `cl.exe` が未設定なら Visual Studio の x64 開発シェルを探して設定します

build driver は生成物を書き換える前に OS / architecture と必要コマンドを検査し、MoonBit・Cargo・Rust のバージョンを診断用に表示します。最低バージョンは固定していません。Cargo 依存は `Cargo.lock` を正本とし、現在は GPUI 0.2.2 に解決されています。

## ビルドと実行

build driver を使用してください。裸の `cargo build` は `gpui-sys/mb_symbol.txt` がないと失敗し、裸の `moon build` は Rust static library 更新後に実行ファイルを再リンクしないことがあります。

### macOS

```bash
./build.sh
./bundle.sh
open dist/Counter.app
# stderr をターミナルで確認する場合
./dist/Counter.app/Contents/MacOS/Counter
```

macOS ではキーボード入力のために `.app` バンドルが必要です。これは macOS 固有の要件であり、他 OS に一般化しません。

### Linux / WSLg

```bash
./build.sh
cd moonbit-bindings
# WSLg では X11 経路を明示する起動方法
env -u WAYLAND_DISPLAY \
  ./_build/native/debug/build/cmd/main/main.exe
# システムの XCB/XKB runtime library が見つからない場合だけ:
LD_LIBRARY_PATH=$PWD/../.linux-libs env -u WAYLAND_DISPLAY \
  ./_build/native/debug/build/cmd/main/main.exe
```

`gpui_run_window` は Wayland 側の panic を C 境界内で捕捉し、`WAYLAND_DISPLAY` を外した X11 で一度だけ再試行します。WSLg では上記の `env -u WAYLAND_DISPLAY` による明示的な起動を推奨します。

### Windows

PowerShell を MSVC x64 環境で開く（または build driver に検出させる）:

```powershell
.\build.ps1
.\moonbit-bindings\_build\native\debug\build\cmd\main\main.exe
```

## build driver が行うこと

`build.sh` と `build.ps1` は OS ごとの link template を選んだうえで、次を実行します。

1. `gpui-sys/abi.toml` から ABI 定数を、C ヘッダーから MoonBit FFI 宣言を生成する。
2. `moon check` を必須ゲートとして実行し、MoonBit を一度 build する。この段階では callback/static library 未解決による想定内の cold-link failure だけを許容する。
3. `app.dispatch` の実マングルシンボルを抽出し、生成 C がある環境では callback が `int32_t` を返し、4 個の `int32_t` 引数を取ることも検証する。
4. `mb_symbol.txt` を読む `gpui-sys` を Rust で build し、Cargo の `native-static-libs` 出力から OS 固有 link flags を生成して MoonBit を強制再リンクする。
5. callback の最終リンクを検証する。macOS/Linux は最終バイナリ上で定義を検査し、Windows は COFF の事情から MoonBit object の定義、Rust archive の未解決参照、最終リンク成功を検査する。

callback のパッケージ/関数は `app.dispatch`、4 個の `i32` 引数という固定契約です。現在の実マングル表記は抽出により追従しますが、`app` package または `dispatch` を改名する場合は、両 build driver の `PKG_FN_SUFFIX` / `$PkgFnSuffix` と ABI 方針も更新する必要があります。

## FFI と実行モデル

MoonBit は Rust 側に retained node tree を組み立て、GPUI が描画します。クリックまたはキーイベントは Rust から MoonBit の `app.dispatch(kind, id, a, b)` に戻ります。callback は状態が変わった場合に `1`、変わらない場合に `0` を返し、`1` のときだけ tree 全体を再構築して Rust が `cx.notify()` を呼びます。未知のイベントや reset 済みの値を再度 reset する操作では再描画しません。

テキスト ABI は `const uint8_t *ptr, int32_t len` です。FFI 宣言の `Bytes` は `#borrow(ptr)` で渡され、高水準の `create_text(String, ...)` が `@utf8.encode` で UTF-8 に変換して明示長とともに渡します。NUL 終端は不要です。

C export の成功 status は `GPUI_STATUS_OK` (0) です。負値は無効 handle、ノード種別違い、移動済みノード、C 境界内で捕捉した panic、トランザクション状態の不備（未開始・二重開始・ルート未指定）、またはコミット時のキー重複を表します。一方、現在の高水準 MoonBit API は setter、トランザクション操作（`begin_tree`/`set_root`/`commit_tree`/`abort_tree`）、`run_window` の status を `ignore` しており、呼び出し元へエラーを公開していません。詳細は [`docs/architecture.md`](docs/architecture.md) を参照してください。

## テストと検証

```bash
cd gpui-sys
GPUI_SYS_ALLOW_TEST_DISPATCH_STUB=1 \
  cargo test --features test-dispatch-stub

cd ../moonbit-bindings
moon check
moon test
```

Rust tests は node store の handle・move-on-attach・status・notification gate・安定キー（重複拒否・未添付ノード無視・click_id との独立）の契約と、`abi.toml` と生成済み Rust/MoonBit ABI 定数の境界横断一致（drift guard）を固定し、MoonBit tests は bindings とイベントの changed/unchanged・rebuild gate を検証します。Linux で XCB/XKB の unversioned development link (`libxcb.so` 等) がない場合、Rust test executable のリンクには `-dev` package または同等のローカル link shim が必要です（root app build は versioned runtime library fallback に対応）。実 callback、生成 ABI、最終リンクの統合検証は root の build driver が担います。root のアクティブな CI はありません。WSL/Linux は 2026-07-21 に full build と安定キー付き GUI（キー付き 4 ボタン）の起動を再確認しました。Windows の最終確認は 2026-07-19、macOS は今回再確認していません。

## ライセンス

Apache-2.0
