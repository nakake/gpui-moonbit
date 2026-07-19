# bindgen-moonbit

CヘッダーファイルからMoonBit FFIバインディングを自動生成するツール。

## 概要

このツールは、C言語のヘッダーファイル（`.h`）を解析し、MoonBitの `extern "C" fn` 宣言を自動生成します。

## インストール

```bash
cargo install --path .
```

## 使い方

```bash
bindgen-moonbit <input.h> [output.mbt]
```

### 例

```bash
# デフォルト出力ファイル名は bindings.mbt
bindgen-moonbit gpui_sys.h

# 出力ファイル名を指定
bindgen-moonbit gpui_sys.h gpui-bindings.mbt
```

## 型マッピング

| C型 | MoonBit型 |
|-----|-----------|
| `int32_t` | `Int` |
| `uint8_t` | `Int` |
| `float` | `Float` |
| `double` | `Double` |
| `void` | `Unit` |
| `const char *`, `char *` | `Bytes` |
| `const uint8_t *`, `uint8_t *` | `Bytes` |

`char *` 系と `uint8_t *` 系の引数は borrowed `Bytes` として生成され、生成される宣言には `#borrow` が付きます。

## 入力例

```c
int32_t gpui_create_div(void);
int32_t gpui_set_size(int32_t handle, float w, float h);
int32_t gpui_create_text(const uint8_t *ptr, int32_t len,
                         uint8_t r, uint8_t g, uint8_t b, float size);
```

## 出力例

```moonbit
extern "C" fn gpui_create_div_ffi() -> Int = "gpui_create_div"
extern "C" fn gpui_set_size_ffi(handle : Int, w : Float, h : Float) -> Int = "gpui_set_size"
#borrow(ptr)
extern "C" fn gpui_create_text_ffi(ptr : Bytes, len : Int, r : Int, g : Int, b : Int, size : Float) -> Int = "gpui_create_text"
```

このツールが生成するのは低水準の FFI 宣言だけです。`String` の UTF-8 `Bytes` への変換は `moonbit-bindings/gpui-bindings.mbt` の高水準ラッパーが担い、このツールはエンコードを行いません。

## 制限事項

- 関数宣言のみ対応（構造体、列挙体、マクロは未対応）
- `char *` 系と `uint8_t *` 系以外のポインタ型は未対応で、`/* type */` として出力
- 関数ポインタ（コールバック）は未対応

## 今後の拡張予定

- 構造体のサポート
- 列挙型のサポート
- 関数ポインタ（`FuncRef[T]`）のサポート
- ドキュメントコメントの生成
