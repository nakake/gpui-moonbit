# トラブルシューティング

GPUI + MoonBit の実装中に遭遇した不具合と、その原因・修正の記録。
同種の問題(FFI での文字列受け渡し、テキスト描画のにじみ/欠け)に再び当たったときの参照用。

参照した GPUI ソースは `gpui v0.2.2`
(`~/.cargo/registry/src/index.crates.io-*/gpui-0.2.2/`)。

---

## 1. テキストが先頭 1 文字しか表示されない

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

### 修正
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

### 検証
```bash
cd moonbit-bindings && moon test    # to_cstring_bytes のテストが通る
moon run cmd/main                   # 全文が表示される
```

### 教訓
**MoonBit native の `String` を C の `const char*` に直接渡してはいけない。**
必ず UTF-8 + NUL 終端の `Bytes` に変換する。`#borrow` は所有権を渡さないだけで
表現(UTF-16 vs UTF-8)の変換はしてくれない。

---

## 2. 先頭文字(例: "G")の左端が約 1px 欠けて見える

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

### 修正
テキストを**前後の空白で挟み、本来の先頭文字を「内部グリフ」にする**。

`gpui-sys/src/lib.rs`(Text ノードの描画)
```rust
let d = div()
    .text_color(rgb(...))
    .text_size(px(*size))
    .child(format!(" {content} "));   // ← 前後に空白
```
- **先頭の空白**が variant 0 の先頭グリフ役を引き受ける(インク無しなので硬い縁は見えない)。
- 本来の先頭文字 "G" の位置は `整数(要素左端) + 空白の字送り(端数)` → **variant 1〜3** →
  語中グリフと同じく AA が乗り、丸みが復活する。
- **末尾の空白**は行幅に算入される(`src/text_system/line_layout.rs`、末尾トリム無しを確認)ので
  中央寄せがずれない。

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
