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
| `const char *` | `String` |
| `char *` | `String` |

## 入力例

```c
int32_t gpui_create_div(void);
void gpui_set_size(int32_t handle, float w, float h);
int32_t gpui_create_text(const char *text, uint8_t r, uint8_t g, uint8_t b, float size);
```

## 出力例

```moonbit
extern "C" fn gpui_create_div_ffi -> Int = "gpui_create_div"
extern "C" fn gpui_set_size_ffi(handle : Int, w : Float, h : Float) -> Unit = "gpui_set_size"
extern "C" fn gpui_create_text_ffi(text : String, r : Int, g : Int, b : Int, size : Float) -> Int = "gpui_create_text"
```

## 制限事項

- 関数宣言のみ対応（構造体、列挙型、マクロは未対応）
- ポインタ型は `char *` のみ対応（他のポインタ型は `/* type */` として出力）
- 関数ポインタ（コールバック）は未対応

## 今後の拡張予定

- 構造体のサポート
- 列挙型のサポート
- 関数ポインタ（`FuncRef[T]`）のサポート
- ドキュメントコメントの生成
