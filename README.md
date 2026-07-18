# GPUI + MoonBit

MoonBitからGPUI（ZedのGPUアクセラレーションUIフレームワーク）を呼び出すプロジェクト。

## プロジェクト構造

```
gpui/
├── gpui-sys/              # Rust C FFI ラッパー
│   ├── src/lib.rs         # GPUIのAPIをC ABIで公開
│   ├── include/gpui_sys.h # 自動生成されたCヘッダー
│   └── Cargo.toml         # gpui v0.2.2 依存
│
├── bindgen-moonbit/       # Cヘッダー → MoonBit FFI 自動生成ツール
│   ├── src/main.rs        # パーサーとコード生成
│   └── README.md          # ツールの使い方
│
├── moonbit-bindings/      # MoonBit プロジェクト
│   ├── gpui-bindings-ffi.mbt  # 自動生成されたFFI宣言
│   ├── gpui-bindings.mbt      # 高レベルAPI（手動）
│   ├── moon.mod               # モジュール設定
│   └── cmd/main/              # デモアプリケーション
│
└── docs/
    ├── architecture.md        # 現行アーキテクチャ(AI向け・具体的な参照先)
    ├── roadmap.md             # ロードマップと進捗
    ├── troubleshooting.md     # 遭遇した不具合と原因・修正の記録
    └── moonbit-native-notes.md # MoonBit native の低レベル仕様メモ(実測・随時追記)
```

## ビルド手順

### 推奨: ワンショットビルド

```bash
./build.sh                       # ビルド(+ 必ず再リンク)
cd moonbit-bindings && moon run cmd/main   # マウス操作のみ確認したい場合
```

**キーボード入力を使う場合は `.app` バンドルが必要**(非バンドルのターミナル起動バイナリには macOS がキーボードイベントを配送しない。マウスは届く):

```bash
./build.sh && ./bundle.sh
open dist/Counter.app                                  # GUI 起動
# または（stderr をターミナルで見たいとき）:
./dist/Counter.app/Contents/MacOS/Counter
```

### Linux

```bash
./build.sh
cd moonbit-bindings
env -u WAYLAND_DISPLAY LD_LIBRARY_PATH=$PWD/../.linux-libs ./_build/native/debug/build/cmd/main/main.exe
```

**既知の問題 (WSLg)**: GPUI 0.2.2 の Wayland バックエンドは、WSLg では
`UnsupportedVersion` で panic する。上記のように `WAYLAND_DISPLAY` を unset し、
X11 (XWayland) バックエンドで起動すること。詳細は
[`docs/troubleshooting.md`](docs/troubleshooting.md#3-wslg-で起動すると-wayland-の-unsupportedversion-で-abort-する)を参照。

`build.sh` は次を自動で行う:
1. MoonBit をコンパイル(`app.dispatch` のマングルシンボルを生成)
2. そのシンボルを `nm` で抽出し `gpui-sys/mb_symbol.txt` に書き出し
3. `gpui-sys` をビルド(`build.rs` が抽出済みシンボルから Rust→MoonBit コールバックの `extern` を生成 + cbindgen でヘッダ生成)
4. 最終リンク(`libgpui_sys.a` + フレームワーク群をリンクし、コールバックを解決)

Rust→MoonBit コールバックは MoonBit のマングル名を参照するため、関数改名やツールチェーンのマングル変更に**自動追従**する(手書き不要)。詳細は [`docs/moonbit-native-notes.md`](docs/moonbit-native-notes.md)。

### 個別ステップ(参考)

- **C API を変更したとき**は FFI を再生成: `cd bindgen-moonbit && cargo run -- ../gpui-sys/include/gpui_sys.h ../moonbit-bindings/gpui-bindings-ffi.mbt`
- **依存フレームワークが変わったとき**(gpui 更新等)はリンク列を再生成して `moonbit-bindings/cmd/main/moon.pkg` の `cc-link-flags` を更新:
  `cd gpui-sys && cargo rustc --lib --crate-type staticlib -- --print native-static-libs`
- 素の `cargo build`(gpui-sys 単体)は `mb_symbol.txt` が未生成だと停止する。`./build.sh` を使うこと。

## アーキテクチャ

```
┌─────────────────────────────────────────────────────────────┐
│  MoonBit コード (gpui-bindings)                              │
│  - create_div(), set_bg(), add_child() などのAPI             │
│  - extern "C" でRustの関数を呼び出す                          │
└────────────────────┬────────────────────────────────────────┘
                     │ MoonBit C FFI
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Rust ライブラリ (gpui-sys)                                  │
│  - #[no_mangle] pub extern "C" fn gpui_create_div() {...}   │
│  - GPUIのAPIを呼び出すラッパー                                │
└────────────────────┬────────────────────────────────────────┘
                     │ Rust FFI
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  GPUI (ZedのUIフレームワーク)                                │
│  - Metal/Vulkan でGPUレンダリング                            │
│  - ウィンドウ管理、イベント処理                               │
└─────────────────────────────────────────────────────────────┘
```

## 型マッピング

| C型 | MoonBit型 |
|-----|-----------|
| `int32_t` | `Int` |
| `uint8_t` | `Int` |
| `float` | `Float` |
| `double` | `Double` |
| `void` | `Unit` |
| `const char *` | `String` |

## デモ

600x500のウィンドウに以下を表示:
- タイトル: "GPUI + MoonBit" (32px)
- サブタイトル: "Native GPU-accelerated UI from MoonBit"
- 5色のカラーボックス (Red, Green, Blue, Yellow, Purple)
- フッター: "Powered by GPUI v0.2.2 | Rendered with Metal"

全てMetal GPUレンダリングで動作。

## 必要条件

- Rust 1.97.0+
- MoonBit toolchain
- Xcode (macOSの場合、Metalレンダリングに必要)

## ライセンス

Apache-2.0
