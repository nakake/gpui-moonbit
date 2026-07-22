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

callback のパッケージ/関数は `app.dispatch`、4 個の `i32` 引数という固定契約です。4 スロットは **バージョニング済みイベントエンベロープ** `(abi_version, event_kind, data_a, data_b)` を運びます。slot 0 は常に `ABI_VERSION` で、古い Rust バイナリをランタイムに拒否します。`EVENT_TEXT` は Rust 所有のイベントキューから `gpui_event_copy_text(token, buf, len)` で UTF-8 ペイロードをコピーします。現在の実マングル表記は抽出により追従しますが、`app` package または `dispatch` を改名する場合は、両 build driver の `PKG_FN_SUFFIX` / `$PkgFnSuffix` と ABI 方針も更新する必要があります。

## FFI と実行モデル

MoonBit は Rust 側に retained node tree を組み立て、GPUI が描画します。ツリーは **コマンドバッファ**（length-delimited な opcode ストリーム）として記述され、`build_tree(view, cb)` 1 回の FFI 呼び出しで送信・コミットされます（issue #5 で property-per-call から集約）。opcode と `BUFFER_VERSION` は `gpui-sys/abi.toml` から両言語へ生成され、drift guard テストが食い違いを検出します。クリック・キー・テキストイベントは Rust から MoonBit の `app.dispatch(version, kind, data_a, data_b)` に戻ります。`EVENT_CLICK` は `(3, 1, click_id, 0)`、`EVENT_KEY` は `(3, 2, codepoint, mods)`、`EVENT_TEXT` は `(3, 3, token, byte_len)` を送り、MoonBit は `gpui_event_copy_text` でペイロードをコピーします。callback は状態が変わった場合に `1`、変わらない場合に `0` を返し、`1` のときだけ tree 全体を再構築して Rust が `cx.notify()` を呼びます。未知のイベントや reset 済みの値を再度 reset する操作では再描画しません。

コマンドバッファ内のテキストは `len u32 + UTF-8 バイト列`（明示長、NUL 終端なし）で、MoonBit は `@utf8.encode` で変換します。Rust はポインタ/長さをその呼び出しの間だけ読み取ります。

C export の成功 status は `GPUI_STATUS_OK` (0) です。負値は無効 handle/スタック、ノード種別違い、移動済みノード、C 境界内で捕捉した panic、バッファの magic/バージョン不一致・切り詰め・未知 opcode・ルート未指定、またはコミット時のキー重複を表します。一方、現在の高水準 MoonBit API `build_tree` は status を `ignore` しており、呼び出し元へエラーを公開していません。詳細は [`docs/architecture.md`](docs/architecture.md) を参照してください。

## テストと検証

```bash
cd gpui-sys
GPUI_SYS_ALLOW_TEST_DISPATCH_STUB=1 \
  cargo test --features test-dispatch-stub

cd ../moonbit-bindings
moon check
moon test
```

Rust tests はコマンドバッファのパース（magic/バージョン・opcode・切り詰め・未知 opcode）・スタック/ハンドル検証・コミット検証（ルート必須・キー重複拒否・click_id 重複許容）・move/forest セマンティクス（attach は move・サブツリー移動・未 attach ノード脱落・最後の set_root 優先）・敵対的文字列長と lossy UTF-8・notification gate の契約と、`abi.toml` と生成済み Rust/MoonBit ABI 定数（opcode と BUFFER_VERSION を含む）の境界横断一致（drift guard）を固定し、MoonBit tests は bindings（色クランプ・埋め込み NUL を含む UTF-8 エンコード）・Rust デコーダレイアウトに対するコマンドバッファのバイト正確なワイヤ形式・イベントの changed/unchanged・rebuild gate を検証します。Linux で XCB/XKB の unversioned development link (`libxcb.so` 等) がない場合、Rust test executable のリンクには `-dev` package または同等のローカル link shim が必要です（例: `RUSTFLAGS="-L ../.linux-libs"`。root app build は versioned runtime library fallback に対応）。実 callback、生成 ABI、最終リンクの統合検証は root の build driver が担います。build driver はさらにヘッドレス往復テスト（`cmd/roundtrip`）を実行し、GUI なしで MoonBit→C→Rust→C→MoonBit の完全な FFI 往復をバイト単位で検証します（issue #34）。GitHub Actions CI（`.github/workflows/ci.yml`）が Linux・macOS・Windows の 3 プラットフォームでコールドビルド・テスト・Rust 専用リビルドを自動検証します。

## ライセンス

Apache-2.0
