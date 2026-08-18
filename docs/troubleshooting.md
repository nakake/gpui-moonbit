# トラブルシューティング

GPUI + MoonBit の実装中に遭遇した不具合と、その原因・修正の記録。
同種の問題(FFI での文字列受け渡し、テキスト描画のにじみ/欠け)に再び当たったときの参照用。

参照した GPUI ソースは `gpui v0.2.2`
(`~/.cargo/registry/src/index.crates.io-*/gpui-0.2.2/`)。

---

## 1. テキストが先頭 1 文字しか表示されない

> **旧 ABI / 修正前の挙動 (履歴)**: この節の症状・原因・コードは、`const char *` の C-string ABI を使っていた時点の記録である。現行 ABI は borrowed `Bytes` を `const uint8_t *ptr + int32_t len` として渡し、UTF-8 に NUL 終端は不要。現行契約は [`architecture.md`](./architecture.md) を参照。

### 症状
`create_text("GPUI + MoonBit", ...)` を描画すると、ウィンドウには **"G" だけ** が表示される。
各テキストが先頭 1 文字に切り詰められる。

### 原因
MoonBit の **native バックエンドの `String` は UTF-16**(`moonbit_string_t = uint16_t*`)で、
**NUL 終端ではない**。これを FFI 経由で C の `const char *` として渡し、Rust 側で
`CStr::from_ptr` を使って NUL 終端 C 文字列として読んでいた。

ASCII 文字列 `"GPUI..."` は UTF-16LE では `0x47 0x00 0x50 0x00 ...` というバイト列になる。
`CStr::from_ptr` は最初の `0x00`(=`'G'` の上位バイト)を終端とみなすため、
**先頭 1 文字だけ** を読み取っていた。

- C ヘッダ: `int32_t gpui_create_text(const char *text, ...)` (`gpui-sys/include/gpui_sys.h`)
- Rust: `CStr::from_ptr(text).to_str()...` (`gpui-sys/src/lib.rs`)
- 旧 FFI: `extern "C" fn gpui_create_text_ffi(text : String, ...)`(String を直接渡していた)

### 当時の修正
MoonBit 側で **UTF-8 にエンコードし NUL 終端を付けた `Bytes`** を渡す方式に変更。
native では `Bytes = uint8_t*`(データを直接指す)なので、NUL 終端 UTF-8 を入れれば
Rust 側の `const char*` + `CStr::from_ptr` がそのまま正しく動く。Rust 側は無変更。

`moonbit-bindings/gpui-bindings.mbt`
```moonbit
fn to_cstring_bytes(text : String) -> Bytes {
  let utf8 = @utf8.encode(text)          // moonbitlang/core/encoding/utf8
  let buf = Buffer(size_hint=utf8.length() + 1)
  buf.write_bytes(utf8)
  buf.write_byte(0)                       // NUL 終端
  buf.to_bytes()
}

pub fn create_text(text : String, r : Int, g : Int, b : Int, size : Float) -> NodeHandle {
  gpui_create_text_ffi(to_cstring_bytes(text), r, g, b, size)
}
```

あわせて:
- `gpui-bindings-ffi.mbt` … `gpui_create_text_ffi` の `text` を `String` → **`Bytes`**
- `moon.pkg` … `moonbitlang/core/encoding/utf8`, `moonbitlang/core/buffer` を import
- `bindgen-moonbit/src/main.rs` … 型マップ `const char *` → **`Bytes`** に変更
  (自動再生成しても `String` に戻らないように。borrow 検出も `Bytes` を含める)
- `gpui-bindings_wbtest.mbt` … `to_cstring_bytes` のユニットテスト
  (`"GPUI + MoonBit"` = 14 文字 + NUL の 15 バイト、途中に NUL 無し、マルチバイト UTF-8、空文字列)

### 当時の検証
```bash
cd moonbit-bindings && moon test    # to_cstring_bytes のテストが通る
moon run cmd/main                   # 全文が表示される
```

### 教訓
**MoonBit native の `String` を C の `const char*` に直接渡してはいけない。**
`#borrow` は所有権を渡さないだけで、表現(UTF-16 vs UTF-8)の変換はしてくれない。

> **現行**: テキストは UTF-8 の borrowed `Bytes` と明示長 (`const uint8_t *ptr + int32_t len`) で渡す。NUL 終端 C 文字列へ変換しない。

---

## 2. 先頭文字(例: "G")の左端が約 1px 欠けて見える

> **macOS 固有の調査記録**: この節は macOS の Metal/CoreText 描画経路を対象にした観測であり、Linux/Windows のレンダリング挙動を示すものではない。

### 症状
`"GPUI + MoonBit"` の先頭 "G" の**左側の丸み**が、約 1px 平らに削れて見える。
各テキストの**先頭文字だけ**に起こり、語中の同じ丸文字("MoonBit" の "o" 等)は正常。

ピクセル輝度で計測すると差がはっきり出る(背景 = 40, 白 = 255):

```
G(先頭グリフ) y54–60   x190 = 40   → x191 = 255       左端に中間調(AA)なし・硬い縁
o(語中グリフ) y58–63   x322 = 85〜135 → x323 = 255     左端に部分被覆(AA)あり・柔らかい縁
```

### 原因(GPUI の描画パイプライン)

GPUI はグリフをアトラス(テクスチャ)に焼いて GPU で貼る。任意のサブピクセル位置ごとに
焼き直すのを避けるため、**水平方向のサブピクセル位置を 4 段階に量子化**してキャッシュする。

`src/text_system.rs`
```rust
pub(crate) const SUBPIXEL_VARIANTS_X: u8 = 4;   // 0, ¼, ½, ¾ px の 4 種
```

描画時、ペン位置の端数から variant を決める。

`src/window.rs`(paint_glyph)
```rust
let glyph_origin = origin.scale(scale_factor);
let subpixel_variant = Point {
    x: (glyph_origin.x.0.fract() * SUBPIXEL_VARIANTS_X as f32).floor() as u8,  // 整数→0, 端数→1..3
    ...
};
```

**核心① 先頭グリフは必ず variant 0 になる**

`src/taffy.rs`
```rust
taffy.enable_rounding();   // レイアウト座標を整数ピクセルに丸める
```
GPUI はレイアウト(taffy)で**要素座標を整数ピクセルに丸める**。したがって:
- 各行の**先頭グリフ**のペン位置 = 要素左端 = 整数 → `fract = 0` → **variant 0**
- **2 文字目以降** = 要素左端 + 字送り(フォント由来の端数)→ 端数 → **variant 1〜3**

→「先頭文字だけ」欠け、語中の丸文字は綺麗だった理由がこれ。

**核心② variant 0 は左端をスナップして硬く描く**

`src/platform/mac/text_system.rs`(rasterize_glyph)
```rust
// Add an extra pixel when the subpixel variant isn't zero to make room for anti-aliasing.
if params.subpixel_variant.x > 0 { bitmap_size.width += DevicePixels(1); }
if params.subpixel_variant.y > 0 { bitmap_size.height += DevicePixels(1); }
```
その後グリフを `subpixel_shift = variant/4 px` ずらして CoreText で描画する。つまり:
- **variant 1〜3**: 端数分ずらして描くので、丸い左カーブのほぼ垂直な接線がピクセルの
  途中に落ち、その列が部分被覆(= AA の中間調)になる → 柔らかい丸い縁。
- **variant 0**: ずらしゼロ・余白ゼロで、接線がピクセル境界にスナップする → 中間調の列が
  できず背景から一気に最大輝度へ。丸い "G" だと**左が 1px 平らにスナップ**されて見える。

> 正確には「切れている」のではなく、**丸い縁が 1px 幅で硬くスナップされている**。

### なぜパディング(`.px(px(2.))`)では直らなかったか
taffy が広げた要素を**再び整数ピクセルへ丸める**ため、テキスト左端はまた整数に戻る。
位相(端数)が変わらず先頭グリフは variant 0 のまま。整数のパディングをいくら足しても同じ。

### 修正（旧・履歴）: 空白で挟む
> **issue #16 で撤廃済み。** 以下の空白パディングはコンテンツ本体を汚染するため、
> 現行の修正は次節「修正（現行）」を参照。

テキストを**前後の空白で挟み、本来の先頭文字を「内部グリフ」にする**。

`gpui-sys/src/lib.rs`(Text ノードの描画・旧コード)
```rust
let d = div()
    .text_color(rgb(...))
    .text_size(px(*size))
    .child(format!(" {content} "));   // ← 前後に空白（撤廃済み）
```
- **先頭の空白**が variant 0 の先頭グリフ役を引き受ける(インク無しなので硬い縁は見えない)。
- 本来の先頭文字 "G" の位置は `整数(要素左端) + 空白の字送り(端数)` → **variant 1〜3** →
  語中グリフと同じく AA が乗り、丸みが復活する。
- **末尾の空白**は行幅に算入される(`src/text_system/line_layout.rs`、末尾トリム無しを確認)ので
  中央寄せがずれない。

### 修正（現行）: レイアウトを汚さない ¼px の描画オフセット（issue #16）

空白パディングはコンテンツ文字列そのものを汚染し、将来の選択/コピー/計測 API を
阻害した（issue #16）。現行の修正は**コンテンツを一切変更せず、描画時だけ先頭
グリフのペン位置を端数にずらす**。

`gpui-sys/src/lib.rs` の `TextGlyphInset` はテキスト要素を包む paint-time 専用の
薄い要素で、レイアウトは子にそのまま委譲（ボックスサイズ・配置は不変）、
prepaint の原点だけを `Window::with_element_offset` で **¼px** 右にずらす。
`Window::layout_bounds` は要素オフセットを子の prepaint bounds に畳み込むため、
先頭グリフのペン位置に ¼px の端数が乗り、**variant 0 → variant 1** となって
語中グリフと同じ AA が乗る。

- コンテンツ文字列は MoonBit が送ったまま。`gpui_debug_dump_text` も素の内容を返す。
- レイアウト空間を一切消費しないため、中央寄せ・兄弟要素の配置は空白パディング
  以前と同等（空白分のずらしも不要）。
- ¼px を選んだ理由: GPUI が実質使うスケール係数 1×/2×/3× では `0.25·n` が整数に
  ならない（½px だと 2× Retina — 本事象の観測プラットフォーム — で再び variant 0
  にスナップする）。4×/8× のように `0.25·n` が整数になるスケールでは variant 0 に
  戻るが、それは GPUI が行頭グリフにデフォルトで描く挙動そのもので、緩和なしより
  悪化することはない。

### 検証
```bash
cd moonbit-bindings && moon run cmd/main   # "G" の左に丸み(階調)が戻る
```

### 教訓
- GPUI は「**整数レイアウト丸め × サブピクセル量子化**」のため、**各行の先頭グリフは常に
  variant 0**(ピクセルスナップ)で描かれる。大きめの丸い先頭文字だと 1px の欠けとして見える。
- これは Zed 本体でも起きているはずだが、通常サイズでは目立たない。今回 32px の見出しで顕在化した。
- 整数パディングでは位相が変わらないので無効。**空白で挟む**か、サブピクセル位置を端数にずらす
  手段が必要。

---

## 3. WSLg で起動すると Wayland の `UnsupportedVersion` で abort する

> **修正前の挙動 (履歴)**: abort に至る症状・原因は修正前の記録である。現行では C 境界内で Wayland 起動 panic を捕捉し、X11 (XWayland) へ一度だけ再試行する。詳細は [`moonbit-native-notes.md` §9](./moonbit-native-notes.md#9-linuxelf--wslg対応での差分) を参照。

### 症状
WSLg 環境でデモを起動すると、GPUI 0.2.2 の
`platform/linux/wayland/client.rs:151` で `UnsupportedVersion` を `unwrap()` して panic する。
panic は `extern "C" gpui_run_window` を越えて unwind できないため、プロセスが abort する。

### 原因
WSLg の Wayland コンポジタが、GPUI 0.2.2 の Wayland バックエンドが要求する
プロトコルバージョンに対応していない。詳細は
[`moonbit-native-notes.md` §9](./moonbit-native-notes.md#9-linuxelf--wslg対応での差分)を参照。

### 現行の修正
`gpui_run_window` は Wayland 初期化の panic を C 境界の内側で捕捉し、
`WAYLAND_DISPLAY` を unset して X11 (XWayland) で一度だけ自動的に再試行する。
通常はそのまま起動できる。

自動フォールバックの成否によらず、WSLg で確実に手動起動するには `moonbit-bindings/` から
`env -u WAYLAND_DISPLAY` で X11 を明示して起動する。

```bash
env -u WAYLAND_DISPLAY LD_LIBRARY_PATH=$PWD/../.linux-libs ./_build/native/debug/build/cmd/main/main.exe
```

---

## 4. build driver が preflight で終了する

root の `build.sh` / `build.ps1` は、生成済み ABI や C ヘッダーを書き換える前に native host/target と必要ツールを検査する。対応範囲は macOS arm64・x86_64、Linux x86_64、Windows MSVC x64 で、cross compile は対象外。

まず driver が表示する `moon` / `cargo` / `rustc` のバージョンと、最初の `ERROR` を確認する。最低バージョンは固定していないため、version 表示自体は診断情報であり、コマンド不在・architecture 不一致・compiler/linker 不在が停止条件になる。

- macOS: Xcode Command Line Tools / Xcode と SDK が必要。`xcrun --show-sdk-path` と `xcrun --find clang` を確認する。
- Linux: `cc` / `c++` / `nm` と XCB/XKB runtime library が必要。システムで見つからない場合だけ、README の `.linux-libs/` fallback を使う。
- Windows: MSVC x64 の `cl.exe` / `link.exe` / `dumpbin.exe` が必要。通常は `build.ps1` が `vswhere` から x64 developer shell を初期化する。

preflight を迂回して生成ファイルを手編集しない。環境を修正して root driver を再実行する。

---

## 5. registry 消費(wrapper 経路)のトラブル

mooncakes からの registry 依存ではモジュールの隣に `gpui-sys/` が無いため、prebuild(`moonbit-bindings/build.py`)がユーザキャッシュに wrapper crate を生成し、crates.io の `gpui-sys` を引いてビルドする(#132、[RFC 0005](./rfc/0005-build-driver-redesign.md))。以下はこの経路に固有の症状で、sibling `gpui-sys/` があるチェックアウト・path/git 依存には当たらない。

### 初回ビルドが異常に長い

wrapper のビルドは gpui の全依存のコールドビルドであり、**数十分かかりネットワーク接続が必要**である。ハングではない。進捗は cargo の出力(prebuild の stderr にそのまま流れる)で確認できる。2 回目以降は共有 target が warm なので高速になる。pin する `gpui-sys` のバージョンが異なるコンシューマを同じ環境で併用すると、共有 target で再ビルドが往復する(ビルドの正しさは保たれる)。

### `no matching package named gpui-sys` で止まる

`gpui-sys` はまだ crates.io に公開されていない(公開はユーザゲート、RFC 0005 PR-C)。公開前に `wrapper-registry` 経路を踏めばこのエラーになるのが正しい挙動である。**ただし意図せずこの経路に入っていないかを先に疑うこと**: リポジトリのチェックアウトや path/git 依存で sibling の `gpui-sys/` が欠けている(clone 失敗・ディレクトリ改名)と、auto 判定が registry 消費と誤解してここへ落ちる。prebuild の stderr に「no sibling gpui-sys at …」の告知が出るのでそれを確認し、チェックアウト意図なら `GPUI_BINDINGS_ROUTE=checkout` で本来の actionable なエラーを得る。公開前に wrapper 機構だけを検証したい場合は、path 依存の wrapper でシミュレートする:

```bash
GPUI_BINDINGS_ROUTE=wrapper-path \
GPUI_BINDINGS_GPUI_SYS_PATH=/path/to/gpui-moonbit/gpui-sys \
  moon build
```

`GPUI_BINDINGS_ROUTE` は `auto`(既定) / `checkout` / `wrapper-path` / `wrapper-registry` を取る検証専用のスイッチで、通常の消費では設定しない。

### ディスクが逼迫する

wrapper と cargo の成果物は 1 環境あたり約 1.2 GB になる。次のディレクトリは丸ごと削除してよい(次回ビルドで再生成・再ビルドされる):

- Linux: `$XDG_CACHE_HOME/nakake-gpui-bindings/`(既定は `~/.cache/nakake-gpui-bindings/`)
- macOS: `~/Library/Caches/nakake-gpui-bindings/`
- Windows: `%LOCALAPPDATA%\nakake-gpui-bindings\`

`CARGO_TARGET_DIR` を設定している場合、cargo の成果物はそちらにあり、キャッシュ配下に残るのは wrapper の manifest 類だけである(依存元ごとに `wrapper/<pin>/<bucket>/` へ分かれる。bucket は依存行のハッシュで、異なる gpui-sys ソースを行き来しても互いの cargo fingerprint を壊さないための分離)。

### Rust(gpui-sys)だけ変えたのに挙動が変わらない(stale exe)

moon は外部 staticlib の変更を追跡しないため、gpui-sys の Rust コードだけを変更して consumer 側で `moon build` しても**実行ファイルは再リンクされない**(CI の relink probe で実測、RFC 0005 §7-2)。prebuild は新しい .a を作るが、リンク済み exe は古いまま残る。回避策: exe を削除してから build する(リポジトリ内の cmd はルートの build driver が自動でこれを行う)。

```bash
rm -f _build/native/debug/build/main/main.exe && moon build
```

### wrapper 経路だけがビルドに失敗する(上流 gpui の浮動)

`gpui-sys/Cargo.lock` は wrapper crate に自動では効かない。ただし **wrapper-path 経路**(検証・CI)では、build.py が依存先 gpui-sys の `Cargo.lock` を wrapper へシード(コピー)するため、解決は checkout と揃う(シードは依存先 lock が変わったときだけ更新される。`.seeded-from` マーカー)。**wrapper-registry 経路**(実際の registry 消費)には lock の供給源が無く、上流 gpui の 0.2.x 系で新しい patch が出ればそれを引き得る。したがって「checkout 経路と wrapper-path が緑のまま、registry 消費だけが赤い」ことが起こり得る。

一次切り分け:

1. 同じコードを checkout 経路(sibling がある状態、または `GPUI_BINDINGS_ROUTE=checkout`)でビルドし、失敗が wrapper 経路に限るかを確かめる。checkout 経路も赤ならこの節の問題ではない。
2. wrapper の lock(`<キャッシュ>/nakake-gpui-bindings/wrapper/<pin>/<bucket>/Cargo.lock`)で解決された gpui のバージョンを、`gpui-sys/Cargo.lock` の値と比べる。
3. 食い違っていてエラーが上流由来なら、wrapper キャッシュを消して再解決する。恒常的に赤くなるようなら wrapper 生成時に gpui を pin することを検討する(RFC 0005 §6 の残存リスク)。

---

## 計測メモ(再現手順)

macOS の Metal ウィンドウは `screencapture -l<windowID>` で撮れないことがある(`could not
create image from window`)。その場合は **領域キャプチャ**を使う:

```bash
# ウィンドウの座標を取得(owner 名は "main.exe")
swift -e 'import CoreGraphics
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]) {
  let o=(w[kCGWindowOwnerName as String] as? String) ?? ""
  if o.lowercased().contains("main"), let b=w[kCGWindowBounds as String] as? [String:Any] {
    print(b) } }'

# 取得した X,Y,W,H で領域キャプチャ(画面全体は撮らない)
screencapture -x -R<X>,<Y>,<W>,<H> shot.png
```

ピクセル輝度は Swift + CoreGraphics で PNG を読み、`(R*30+G*59+B*11)/100` で確認できる。
`sips -z <h> <w>` で最近傍ではなくスムージング拡大になる点に注意(1px の判定は輝度ダンプで行う)。
