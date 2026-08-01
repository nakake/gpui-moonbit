// High-level API for GPUI.
//
// The whole UI tree is described as one length-delimited command buffer
// (`CommandBuffer`) and submitted with a single `build_tree` FFI call, replacing
// the former property-per-call surface (issue #5). Opcodes and BUFFER_VERSION
// are generated from `gpui-sys/abi.toml` into `abi_constants.mbt`, so a drift
// between the encoder here and the Rust decoder fails the cross-boundary
// constant check rather than corrupting at runtime.
//
// FFI declarations are auto-generated in gpui-bindings-ffi.mbt.

// --- Structured errors and diagnostics (issue #54, G20/G21) -----------------
//
// The Rust side answers across the C boundary with negative `GPUI_STATUS_*`
// codes; `build_tree`/`run_window` surface them as `Err(Int)`. The helpers
// below classify a raw code into a structured, printable `GpuiError` so app
// authors never have to decode a bare negative integer.

///|
/// Rust 側が返す負の `GPUI_STATUS_*` コードに対応する構造化エラーです。生のコードは
/// `classify_status` でこの型に変換でき、`message` / `to_string` で 1 行の診断メッセージを
/// 得られます。既知の範囲外のコードは `Unknown(code)` になります。
pub enum GpuiError {
  InvalidHandle // GPUI_STATUS_INVALID_HANDLE (-1)
  WrongNodeKind // GPUI_STATUS_WRONG_NODE_KIND (-2)
  NodeAbsent // GPUI_STATUS_NODE_ABSENT (-3)
  InternalPanic // GPUI_STATUS_INTERNAL_PANIC (-4)
  BadBufferVersion // GPUI_STATUS_BAD_BUFFER_VERSION (-5)
  TruncatedBuffer // GPUI_STATUS_TRUNCATED_BUFFER (-6)
  UnknownOpcode // GPUI_STATUS_UNKNOWN_OPCODE (-7)
  NoRoot // GPUI_STATUS_NO_ROOT (-8)
  DuplicateKey // GPUI_STATUS_DUPLICATE_KEY (-9)
  KeyNotFound // GPUI_STATUS_KEY_NOT_FOUND (-10)
  QueueFull // GPUI_STATUS_QUEUE_FULL (-11)
  PayloadTooLarge // GPUI_STATUS_PAYLOAD_TOO_LARGE (-12)
  Unknown(Int) // any other code
}

///|
/// Rust FFI が返した生の status コードを構造化された `GpuiError` に分類します。
/// 既知の負コードはそれぞれの variant に対応し、それ以外（成功の `0` を含む）は
/// `Unknown(code)` になります。
pub fn classify_status(code : Int) -> GpuiError {
  match code {
    -1 => InvalidHandle
    -2 => WrongNodeKind
    -3 => NodeAbsent
    -4 => InternalPanic
    -5 => BadBufferVersion
    -6 => TruncatedBuffer
    -7 => UnknownOpcode
    -8 => NoRoot
    -9 => DuplicateKey
    -10 => KeyNotFound
    -11 => QueueFull
    -12 => PayloadTooLarge
    _ => Unknown(code)
  }
}

///|
/// 生の status コードに対する 1 行の人間が読める診断メッセージを返します
/// （ログ・ツール間でポータブルな英語です）。
pub fn status_message(code : Int) -> String {
  match classify_status(code) {
    InvalidHandle => "invalid handle: negative, out of range, or unallocated"
    WrongNodeKind => "wrong node kind for the requested operation"
    NodeAbsent => "node already moved into another node"
    InternalPanic => "internal Rust panic caught at the FFI boundary"
    BadBufferVersion => "command buffer magic or version mismatch"
    TruncatedBuffer => "command buffer truncated or oversized"
    UnknownOpcode => "command buffer names an unknown opcode"
    NoRoot => "command buffer committed without OP_SET_ROOT"
    DuplicateKey => "duplicate explicit key in the committed tree"
    KeyNotFound => "no keyed text node matches in the committed tree"
    QueueFull => "async injection queue is full: retry later, coalesce, or drop"
    PayloadTooLarge =>
      "async injection payload exceeds the per-entry size limit"
    Unknown(c) => "unknown status code \{c}"
  }
}

///|
/// このエラーが分類された元の `GPUI_STATUS_*` コードを返します（未知のコードはそのまま保持されます）。
pub fn GpuiError::code(self : GpuiError) -> Int {
  match self {
    InvalidHandle => -1
    WrongNodeKind => -2
    NodeAbsent => -3
    InternalPanic => -4
    BadBufferVersion => -5
    TruncatedBuffer => -6
    UnknownOpcode => -7
    NoRoot => -8
    DuplicateKey => -9
    KeyNotFound => -10
    QueueFull => -11
    PayloadTooLarge => -12
    Unknown(c) => c
  }
}

///|
/// このエラーの 1 行の人間が読める診断メッセージを返します。
pub fn GpuiError::message(self : GpuiError) -> String {
  status_message(self.code())
}

///|
/// `GpuiError(<code>): <message>` 形式の表示可能な表現を返します。`to_string` を定義することで
/// `GpuiError` は文字列補間 `\{...}` でもそのまま使えます。
pub fn GpuiError::to_string(self : GpuiError) -> String {
  "GpuiError(\{self.code()}): \{self.message()}"
}

///|
/// `r` が `Err(status)` のとき、文脈 `ctx` を前置した構造化診断メッセージで abort します。
/// FFI 失敗から回復できない呼び出し点を簡潔にします。
pub fn expect_ok(r : Result[Unit, Int], ctx : String) -> Unit {
  match r {
    Ok(_) => ()
    Err(status) => {
      let err = classify_status(status)
      abort("\{ctx}: \{err.to_string()}")
    }
  }
}

///|
fn clamp_color_component(value : Int) -> Int {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}

// --- G9: color abstraction with alpha (issue #51) --------------------------

///|
/// RGBA 色。各成分は 0–255 の整数です（範囲外は送信時にクランプされます）。
/// 従来の `set_bg(r, g, b)` に加え、alpha 通道を持つ色を `set_bg_color` で指定できます。
pub struct Color {
  red : Int
  green : Int
  blue : Int
  alpha : Int
}

///|
/// 不透明（alpha 255）な RGB 色を作成します。
pub fn Color::rgb(red : Int, green : Int, blue : Int) -> Color {
  { red, green, blue, alpha: 255 }
}

///|
/// alpha 通道付きの RGBA 色を作成します。
pub fn Color::rgba(red : Int, green : Int, blue : Int, alpha : Int) -> Color {
  { red, green, blue, alpha }
}

///|
/// 黒（不透明）。
pub fn Color::black() -> Color {
  Color::rgb(0, 0, 0)
}

///|
/// 白（不透明）。
pub fn Color::white() -> Color {
  Color::rgb(255, 255, 255)
}

///|
/// 完全透明。
pub fn Color::transparent() -> Color {
  Color::rgba(0, 0, 0, 0)
}

// MoonBit's native `String` is UTF-16, so encode it to UTF-8 for the byte-based
// Rust FFI. The explicit byte length means no NUL terminator is needed.

///|
fn to_utf8_bytes(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// 1 つの UI ツリーを記述する length-delimited なコマンドバッファです。ノード生成は
/// 内部スタック（Rust 側）へハンドルをプッシュし、setter はスタックトップに適用
/// されます。`add_child` は子→親の順にポップして親を再プッシュし、`set_root` は
/// ルートをポップします。複数バイト値はすべて little-endian です。`build_tree` で
/// 送信します。
pub struct CommandBuffer {
  buf : @buffer.Buffer
}

///|
/// 空のコマンドバッファを作成します。ヘッダ（magic "GPUI" と BUFFER_VERSION、
/// u32 little-endian）を自動的に書き込みます。
pub fn CommandBuffer::new() -> CommandBuffer {
  let buf = Buffer()
  // Header: magic "GPUI" + BUFFER_VERSION (u32 LE).
  buf.write_bytes(b"GPUI".view())
  buf.write_uint_le(BUFFER_VERSION.reinterpret_as_uint())
  { buf, }
}

///|
fn CommandBuffer::op(self : CommandBuffer, opcode : Int) -> Unit {
  self.buf.write_byte(opcode.to_byte())
}

///|
fn CommandBuffer::write_str(self : CommandBuffer, text : String) -> Unit {
  let utf8 = to_utf8_bytes(text)
  self.buf.write_uint_le(utf8.length().reinterpret_as_uint())
  self.buf.write_bytes(utf8.view())
}

///|
/// 新しい div をプッシュします。プッシュしたノードはスタックトップになります。
pub fn CommandBuffer::div(self : CommandBuffer) -> Unit {
  self.op(OP_DIV)
}

///|
/// 新しいテキストノードをプッシュします（RGB 各成分は 0–255 にクランプ）。プッシュしたノードはスタックトップになります。テキスト色を `Color`（alpha 付き）で指定する場合は `text` の後に `set_text_color(color)` を呼んでください。
pub fn CommandBuffer::text(
  self : CommandBuffer,
  content : String,
  r : Int,
  g : Int,
  b : Int,
  size : Float,
) -> Unit {
  self.op(OP_TEXT)
  self.write_str(content)
  self.buf.write_byte(clamp_color_component(r).to_byte())
  self.buf.write_byte(clamp_color_component(g).to_byte())
  self.buf.write_byte(clamp_color_component(b).to_byte())
  self.buf.write_float_le(size)
}

///|
/// スタックトップの div にサイズ（幅・高さ）を設定します。
pub fn CommandBuffer::set_size(
  self : CommandBuffer,
  w : Float,
  h : Float,
) -> Unit {
  self.op(OP_SET_SIZE)
  self.buf.write_float_le(w)
  self.buf.write_float_le(h)
}

///|
/// スタックトップの div の背景色を設定します（RGB 各成分は 0–255 にクランプ）。alpha 付きの `Color` で指定する場合は `set_bg_color(color)` を使ってください。
pub fn CommandBuffer::set_bg(
  self : CommandBuffer,
  r : Int,
  g : Int,
  b : Int,
) -> Unit {
  self.op(OP_SET_BG)
  self.buf.write_byte(clamp_color_component(r).to_byte())
  self.buf.write_byte(clamp_color_component(g).to_byte())
  self.buf.write_byte(clamp_color_component(b).to_byte())
}

///|
/// スタックトップの div を flex row（横並び）レイアウトにします。
pub fn CommandBuffer::set_flex_row(self : CommandBuffer) -> Unit {
  self.op(OP_SET_FLEX)
  self.buf.write_byte(b'\x00')
}

///|
/// スタックトップの div を flex column（縦並び）レイアウトにします。
pub fn CommandBuffer::set_flex_col(self : CommandBuffer) -> Unit {
  self.op(OP_SET_FLEX)
  self.buf.write_byte(b'\x01')
}

///|
/// スタックトップの div の子要素を中央揃えにします。
pub fn CommandBuffer::set_center(self : CommandBuffer) -> Unit {
  self.op(OP_SET_CENTER)
}

///|
/// スタックトップの div の子要素間ギャップを設定します。
pub fn CommandBuffer::set_gap(self : CommandBuffer, gap : Float) -> Unit {
  self.op(OP_SET_GAP)
  self.buf.write_float_le(gap)
}

///|
/// スタックトップの div の角丸半径を設定します。
pub fn CommandBuffer::set_rounded(self : CommandBuffer, radius : Float) -> Unit {
  self.op(OP_SET_ROUNDED)
  self.buf.write_float_le(radius)
}

///|
/// スタックトップの div をクリック可能にします。`click_id` はクリック時に
/// `dispatch` の `data_a` としてルーティングされます。
pub fn CommandBuffer::set_on_click(
  self : CommandBuffer,
  click_id : Int,
) -> Unit {
  self.op(OP_SET_ON_CLICK)
  self.buf.write_int_le(click_id)
}

///|
/// スタックトップの div に、クリックルーティングとは独立した安定した識別子を
/// 付与します。キーは GPUI の element id となり、再構築をまたいで stateful element
/// の識別を維持します。1 ツリー内のキー重複は拒否されます。
pub fn CommandBuffer::set_key(self : CommandBuffer, key : String) -> Unit {
  self.op(OP_SET_KEY)
  self.write_str(key)
}

///|
/// スタックトップの div に均一な padding を設定します。
pub fn CommandBuffer::set_padding(
  self : CommandBuffer,
  padding : Float,
) -> Unit {
  self.op(OP_SET_PADDING)
  self.buf.write_float_le(padding)
}

///|
/// スタックトップの div に枠線を設定します。均一な太さと RGB 色（0–255 にクランプ）
/// を取ります。太さが 0 以下の場合は枠線を描画しません。alpha 付きの `Color` で指定する場合は `set_border_color(width, color)` を使ってください。
pub fn CommandBuffer::set_border(
  self : CommandBuffer,
  width : Float,
  r : Int,
  g : Int,
  b : Int,
) -> Unit {
  self.op(OP_SET_BORDER)
  self.buf.write_float_le(width)
  self.buf.write_byte(clamp_color_component(r).to_byte())
  self.buf.write_byte(clamp_color_component(g).to_byte())
  self.buf.write_byte(clamp_color_component(b).to_byte())
}

///|
/// スタックトップの div に枠線を `Color`（alpha 付き）で設定します。均一な太さと
/// 色（各成分 0–255 にクランプ）を取ります。太さが 0 以下の場合は枠線を描画しません。
/// `set_border(width, r, g, b)` は引き続き利用可能で、wire format は同一です。
pub fn CommandBuffer::set_border_color(
  self : CommandBuffer,
  width : Float,
  color : Color,
) -> Unit {
  self.op(OP_SET_BORDER)
  self.buf.write_float_le(width)
  self.buf.write_byte(clamp_color_component(color.red).to_byte())
  self.buf.write_byte(clamp_color_component(color.green).to_byte())
  self.buf.write_byte(clamp_color_component(color.blue).to_byte())
}

// --- G7 core layout/style + G9 color (issue #51) ---------------------------

///|
/// スタックトップの div の背景色を `Color`（alpha 付き）で設定します。各成分は
/// 0–255 にクランプされます。`set_bg(r, g, b)` は引き続き利用可能で、両方設定した
/// 場合はこちらが優先されます。
pub fn CommandBuffer::set_bg_color(self : CommandBuffer, color : Color) -> Unit {
  self.op(OP_SET_BG_COLOR)
  self.buf.write_byte(clamp_color_component(color.red).to_byte())
  self.buf.write_byte(clamp_color_component(color.green).to_byte())
  self.buf.write_byte(clamp_color_component(color.blue).to_byte())
  self.buf.write_byte(clamp_color_component(color.alpha).to_byte())
}

///|
/// スタックトップの div に辺別の margin（外余白、px）を設定します。
/// 引数の順は top, right, bottom, left です。
pub fn CommandBuffer::set_margin(
  self : CommandBuffer,
  top : Int,
  right : Int,
  bottom : Int,
  left : Int,
) -> Unit {
  self.op(OP_SET_MARGIN)
  self.buf.write_int_le(top)
  self.buf.write_int_le(right)
  self.buf.write_int_le(bottom)
  self.buf.write_int_le(left)
}

///|
/// スタックトップの div に最小サイズ（px）を設定します。辺ごとに負値（例: -1）を
/// 渡すとその辺は auto（無指定）になります。
pub fn CommandBuffer::set_min_size(
  self : CommandBuffer,
  w : Int,
  h : Int,
) -> Unit {
  self.op(OP_SET_MIN_SIZE)
  self.buf.write_int_le(w)
  self.buf.write_int_le(h)
}

///|
/// スタックトップの div に最大サイズ（px）を設定します。辺ごとに負値（例: -1）を
/// 渡すとその辺は auto（無指定）になります。
pub fn CommandBuffer::set_max_size(
  self : CommandBuffer,
  w : Int,
  h : Int,
) -> Unit {
  self.op(OP_SET_MAX_SIZE)
  self.buf.write_int_le(w)
  self.buf.write_int_le(h)
}

///|
/// スタックトップの div を flex item として設定します。`grow` / `shrink` は比率
/// （Float、例: 1.0 / 0.5）で、内部では ×1000 の整数として送られます。`basis` は
/// 主軸の初期サイズ（px）で、負値（例: -1.0）は auto を意味します。
pub fn CommandBuffer::set_flex(
  self : CommandBuffer,
  grow : Float,
  shrink : Float,
  basis : Float,
) -> Unit {
  self.op(OP_SET_FLEX_ITEM)
  self.buf.write_int_le((grow * 1000.0).to_int())
  self.buf.write_int_le((shrink * 1000.0).to_int())
  self.buf.write_int_le(basis.to_int())
}

///|
/// スタックトップの div の子要素の整列を設定します。`align_items` は交差軸方向の
/// 揃え（`ALIGN_*` 定数）、`justify_content` は主軸方向の配置（`JUSTIFY_*` 定数）です。
/// それぞれ 0（`ALIGN_DEFAULT` / `JUSTIFY_DEFAULT`）を渡すとその軸は無指定のままです。
pub fn CommandBuffer::set_align(
  self : CommandBuffer,
  align_items : Int,
  justify_content : Int,
) -> Unit {
  self.op(OP_SET_ALIGN)
  self.buf.write_int_le(align_items)
  self.buf.write_int_le(justify_content)
}

///|
/// スタックトップの div の overflow（はみ出しの扱い）を軸別に設定します。
/// `OVERFLOW_VISIBLE` / `OVERFLOW_HIDDEN` / `OVERFLOW_SCROLL` を渡します。
/// `SCROLL` を指定した軸は実際のスクロールになります。Rust 側はスクロール div に
/// 保持された `ScrollHandle` を割り当て、`set_key` でキーを付けた div は再構築をまたいで
/// スクロール位置を維持します（キーなしのスクロール div は毎回の再構築で先頭に戻ります）。
pub fn CommandBuffer::set_overflow(
  self : CommandBuffer,
  x : Int,
  y : Int,
) -> Unit {
  self.op(OP_SET_OVERFLOW)
  self.buf.write_int_le(x)
  self.buf.write_int_le(y)
}

///|
/// スタックトップの div（とその子孫）の不透明度を設定します。0.0（完全透明）〜
/// 1.0（完全不透明）の Float を取り、内部では ×1000 の整数として送られます。
pub fn CommandBuffer::set_opacity(
  self : CommandBuffer,
  opacity : Float,
) -> Unit {
  self.op(OP_SET_OPACITY)
  self.buf.write_int_le((opacity * 1000.0).to_int())
}

///|
/// スタックトップの div にボックスシャドウを設定します。`x` / `y` はオフセット、
/// `blur` はぼかし半径、`spread` は広がり（いずれも px、負値可）、`color` は影の色
/// （alpha 付き）です。
pub fn CommandBuffer::set_shadow(
  self : CommandBuffer,
  x : Int,
  y : Int,
  blur : Int,
  spread : Int,
  color : Color,
) -> Unit {
  self.op(OP_SET_SHADOW)
  self.buf.write_int_le(x)
  self.buf.write_int_le(y)
  self.buf.write_int_le(blur)
  self.buf.write_int_le(spread)
  self.buf.write_byte(clamp_color_component(color.red).to_byte())
  self.buf.write_byte(clamp_color_component(color.green).to_byte())
  self.buf.write_byte(clamp_color_component(color.blue).to_byte())
  self.buf.write_byte(clamp_color_component(color.alpha).to_byte())
}

///|
/// スタックトップの div 上のマウスカーソル形状を設定します。`CURSOR_*` 定数
/// （`CURSOR_ARROW` / `CURSOR_POINTER` / `CURSOR_TEXT` など）を渡します。クリック可能
/// な div ではクリック時のポインタ表示が優先されます。
pub fn CommandBuffer::set_cursor(self : CommandBuffer, kind : Int) -> Unit {
  self.op(OP_SET_CURSOR)
  self.buf.write_int_le(kind)
}

///|
/// スタックトップの div の配置モードを設定します。`POSITION_ABSOLUTE` を渡すと
/// レイアウトから外れ、`set_inset` の値で位置が決まります。`POSITION_RELATIVE`
/// （既定）に戻すこともできます。
pub fn CommandBuffer::set_position(self : CommandBuffer, mode : Int) -> Unit {
  self.op(OP_SET_POSITION)
  self.buf.write_int_le(mode)
}

///|
/// 配置済み要素の inset（top, right, bottom, left、px）を設定します。辺ごとに負値
/// （例: -1）を渡すとその辺は auto になります。`set_position(POSITION_ABSOLUTE)` と
/// 組み合わせて使います。
pub fn CommandBuffer::set_inset(
  self : CommandBuffer,
  top : Int,
  right : Int,
  bottom : Int,
  left : Int,
) -> Unit {
  self.op(OP_SET_INSET)
  self.buf.write_int_le(top)
  self.buf.write_int_le(right)
  self.buf.write_int_le(bottom)
  self.buf.write_int_le(left)
}

///|
/// スタックトップの div に辺別の padding（内余白、px）を設定します。引数の順は
/// top, right, bottom, left です。均一の `set_padding` より優先されます。
pub fn CommandBuffer::set_padding_sides(
  self : CommandBuffer,
  top : Int,
  right : Int,
  bottom : Int,
  left : Int,
) -> Unit {
  self.op(OP_SET_PADDING_SIDES)
  self.buf.write_int_le(top)
  self.buf.write_int_le(right)
  self.buf.write_int_le(bottom)
  self.buf.write_int_le(left)
}

// --- G8 typography (issue #51) ----------------------------------------------
//
// These setters apply to the div on top of the stack and are inherited by all
// descendant text nodes: the Rust side stores them on the div's `Style.text`
// refinement, which gpui pushes around child layout/paint. Rich text (partial
// decoration within one text node) is out of scope — see docs/framework-gaps.md G8.

///|
/// スタックトップの div（とその子孫のテキスト）のフォントサイズ（px）を設定します。
/// テキストノード自体のサイズは `text` 呼び出しで指定しますが、この値は div 配下の
/// すべてのテキストに継承されます。
pub fn CommandBuffer::set_text_size(self : CommandBuffer, size : Int) -> Unit {
  self.op(OP_SET_TEXT_SIZE)
  self.buf.write_int_le(size)
}

///|
/// スタックトップの div（とその子孫のテキスト）のテキスト色を `Color`（alpha 付き）
/// で設定します。各成分は 0–255 にクランプされます。
pub fn CommandBuffer::set_text_color(
  self : CommandBuffer,
  color : Color,
) -> Unit {
  self.op(OP_SET_TEXT_COLOR)
  self.buf.write_byte(clamp_color_component(color.red).to_byte())
  self.buf.write_byte(clamp_color_component(color.green).to_byte())
  self.buf.write_byte(clamp_color_component(color.blue).to_byte())
  self.buf.write_byte(clamp_color_component(color.alpha).to_byte())
}

///|
/// スタックトップの div（とその子孫のテキスト）のフォントウェイトを設定します。
/// 100（極細）〜900（極太）の整数で、400 が標準、700 が太字相当です。範囲外の値は
/// Rust 側で 100–900 にクランプされます。
pub fn CommandBuffer::set_font_weight(
  self : CommandBuffer,
  weight : Int,
) -> Unit {
  self.op(OP_SET_FONT_WEIGHT)
  self.buf.write_int_le(weight)
}

///|
/// スタックトップの div（とその子孫のテキスト）の行の高さ（px）を設定します。
/// Float で渡し、内部では ×1000 の整数として送られます（例: 1.5 → 1500）。負値
/// （例: -1.0）は設定解除で、gpui の既定（黄金比）に戻ります。
pub fn CommandBuffer::set_line_height(
  self : CommandBuffer,
  line_height : Float,
) -> Unit {
  self.op(OP_SET_LINE_HEIGHT)
  self.buf.write_int_le((line_height * 1000.0).to_int())
}

///|
/// スタックトップの div（とその子孫のテキスト）のテキスト配置を設定します。
/// `TEXT_ALIGN_LEFT` / `TEXT_ALIGN_CENTER` / `TEXT_ALIGN_RIGHT` / `TEXT_ALIGN_JUSTIFY`
/// を渡します。`TEXT_ALIGN_DEFAULT`（0）は無指定です。注: gpui 0.2.2 の `TextAlign`
/// に `Justify` がないため、`TEXT_ALIGN_JUSTIFY` は左揃えとして描画されます。
pub fn CommandBuffer::set_text_align(self : CommandBuffer, align : Int) -> Unit {
  self.op(OP_SET_TEXT_ALIGN)
  self.buf.write_int_le(align)
}

///|
/// スタックトップの div（とその子孫のテキスト）の空白・折り返しの扱いを設定します。
/// `WHITESPACE_NORMAL`（幅に合わせて折り返す）/ `WHITESPACE_NOWRAP`（折り返さない）
/// を渡します。`WHITESPACE_DEFAULT`（0）は無指定です。注: gpui 0.2.2 の `WhiteSpace`
/// は Normal/Nowrap のみで、`WHITESPACE_PRE` は NOWRAP、`WHITESPACE_PRE_WRAP` は
/// NORMAL として扱われます。
pub fn CommandBuffer::set_whitespace(
  self : CommandBuffer,
  whitespace : Int,
) -> Unit {
  self.op(OP_SET_WHITESPACE)
  self.buf.write_int_le(whitespace)
}

///|
/// スタックトップの div（とその子孫のテキスト）のフォントファミリー名を設定します
/// （例: "Fira Code"）。指定した名前のフォントがシステムに存在しない場合の代替挙動は
/// gpui のフォント解決に依存します。
pub fn CommandBuffer::set_font_family(
  self : CommandBuffer,
  family : String,
) -> Unit {
  self.op(OP_SET_FONT_FAMILY)
  self.write_str(family)
}

// --- Keyboard navigation / a11y (issue #52) --------------------------------
//
// gpui 0.2.2 has no accessibility role/label/screen-reader API (the Element
// trait is id/layout/paint only), but keyboard focus navigation is fully
// public. These setters mark a div focusable and order it in the Tab cycle;
// the Rust side drives Tab/Shift+Tab traversal via window.focus_next/prev.
// See docs/a11y-ime.md for the full boundary.

///|
/// スタックトップの div をキーボードフォーカス可能にします。`focusable` が真（非 0）の
/// とき、その div はフォーカスを受け取れる要素（gpui の `.focusable()`）になります。
/// フォーカス可能な div は Tab / Shift+Tab のトラバース対象です。要素の識別子（id）が
/// 必要なため、`set_key` や `set_on_click` で id を持たない div には Rust 側が毎レンダー
/// 一時 id を合成します（再構築のたびにフォーカスハンドルがリセットされるため、再構築を
/// またいでフォーカスを維持したい場合は `set_key` を付けてください）。
pub fn CommandBuffer::set_focusable(
  self : CommandBuffer,
  focusable : Int,
) -> Unit {
  self.op(OP_SET_FOCUSABLE)
  self.buf.write_int_le(focusable)
}

///|
/// スタックトップの div の Tab 順序（tab index）を設定します。gpui の `.tab_index()` に
/// 対応し、この呼び出しは要素をフォーカス可能かつ tab stop にもします。値の小さい順に
/// Tab で巡ります。`set_tab_stop(0)` と組み合わせると、順序には残しつつ Tab 移動からは
/// 外せます。
pub fn CommandBuffer::set_tab_index(self : CommandBuffer, index : Int) -> Unit {
  self.op(OP_SET_TAB_INDEX)
  self.buf.write_int_le(index)
}

///|
/// スタックトップの div が Tab キーで到達できる tab stop かどうかを設定します。gpui の
/// `.tab_stop()` に対応します。`tab_stop` が 0 のとき、要素は tab index 順序には残るもの
/// のキーボードナビゲーションではスキップされます（コンテナにフォーカスを与えつつ自身は
/// Tab で辿らせない用途など）。`set_tab_index` と組み合わせて使います。
pub fn CommandBuffer::set_tab_stop(
  self : CommandBuffer,
  tab_stop : Int,
) -> Unit {
  self.op(OP_SET_TAB_STOP)
  self.buf.write_int_le(tab_stop)
}

///|
/// スタックトップのノード（子）をその 1 つ下のノード（親）に接続します。
/// 親はスタックトップに残るため、続けて別の子を接続できます。
pub fn CommandBuffer::add_child(self : CommandBuffer) -> Unit {
  self.op(OP_ADD_CHILD)
}

///|
/// スタックトップのノードをツリーのルートに指定します。
pub fn CommandBuffer::set_root(self : CommandBuffer) -> Unit {
  self.op(OP_SET_ROOT)
}

///|
/// 蓄積したコマンドをワイヤ形式のバイト列にシリアライズします。
pub fn CommandBuffer::to_bytes(self : CommandBuffer) -> Bytes {
  self.buf.to_bytes()
}

///|
/// `view` 用のツリーを 1 つのコマンドバッファから構築・コミットし、前回コミット済み
/// のツリーを置き換えます。ツリー全体の送信はこの 1 回の FFI 呼び出しで行います。
/// 失敗時は負の `GPUI_STATUS_*` コードを `Err(status)` で返し、前回コミット済みの
/// ツリーはそのまま保持されます（atomic commit）。
pub fn build_tree(view : Int, cb : CommandBuffer) -> Result[Unit, Int] {
  let bytes = cb.to_bytes()
  let status = gpui_build_tree_ffi(view, bytes, bytes.length())
  if status == 0 {
    Ok(())
  } else {
    Err(status)
  }
}

///|
/// `view` にコミット済みのツリーで、`key`（`set_key` で付けた安定 ID）を持つ div の
/// テキストを**その場で**更新します（issue #10: 計測で正当化したインクリメンタル更新）。
/// ツリー全体を再送信する `build_tree` とは異なり、キー付きノードのテキスト子だけを
/// 書き換えるため、デコードもツリー再構築も起きません。再描画は既存の dispatch→notify
/// 経路（`dispatch` が 1 を返す → Rust が `cx.notify()` → `render_node` が更新済みの
/// `VIEWS[view]` を読む）でそのまま行われます。
///
/// 対象ノードが見つからない場合（ツリー未コミット、キー不一致、キー付き div にテキスト
/// 子がない）は `Err(GPUI_STATUS_KEY_NOT_FOUND)` を返すので、呼び出し側は `build_tree` に
/// フォールバックしてください。フルリビルド経路は引き続き既定の正しいフォールバック
/// です。これは opt-in の最適化であり、汎用 vdom diff は意図的に実装していません。
pub fn update_text(
  view : Int,
  key : String,
  text : String,
) -> Result[Unit, Int] {
  let key_bytes = to_utf8_bytes(key)
  let text_bytes = to_utf8_bytes(text)
  let status = gpui_update_text_ffi(
    view,
    key_bytes,
    key_bytes.length(),
    text_bytes,
    text_bytes.length(),
  )
  if status == 0 {
    Ok(())
  } else {
    Err(status)
  }
}

///|
/// GPUI ウィンドウを開き、`view` にコミット済みのツリーを描画してイベントループで
/// ブロックします。`view` は `build_tree` が設定する Rust 側 view slot の index です。
/// ウィンドウ生成に失敗した場合、またはイベントループが panic した場合は
/// `Err(status)` を返します。
pub fn run_window(
  view : Int,
  width : Float,
  height : Float,
) -> Result[Unit, Int] {
  let status = gpui_run_window_ffi(view, width, height)
  if status == 0 {
    Ok(())
  } else {
    Err(status)
  }
}

// --- Async event injection (RFC 0002, issue #84) ---------------------------
//
// `gpui_post_event` lets any thread push an opaque payload into a bounded
// queue; the main thread drains it and dispatches each entry as `EVENT_ASYNC`
// through the same `dispatch` callback the input events use. The payload rides
// the `EVENT_QUEUE` token+copy mechanism, so the handler copies it
// synchronously with `copy_async_payload` before `dispatch` returns.

///|
/// 任意のスレッドから `view` 宛ての非同期イベントを注入します（RFC 0002 §3.1）。
/// ペイロードは呼び出し中にコピーされ、呼び出しは即座に戻ります（ブロックしません）。
/// 本体は opaque なバイト列で、ライブラリは一切解釈しません。フレーミングは生産者と
/// MoonBit 側の `Event::Async` ハンドラの間の契約です。
///
/// `view` は宛先の view id（`VIEWS` の index）で、負値は即座に失敗します。未知の view
/// 宛ては post 自体は成功しますが、drain 時に破棄されます（RFC 0002 §6-2）。`payload`
/// は長さ 0 でもよく、「何かが起きた」をペイロードなしで伝えられます。
///
/// 戻り値: 成功は `Ok(())`。失敗は `Err(status)` で、`GPUI_STATUS_INVALID_HANDLE`
/// （負の view、または非ゼロ長でヌルポインタ）、`GPUI_STATUS_PAYLOAD_TOO_LARGE`
/// （1 エントリの上限超過）、`GPUI_STATUS_QUEUE_FULL`（キュー満杯: 後で再試行するか、
/// 集約・破棄してください。ライブラリはブロックも破棄も集約もしません）のいずれかです。
/// ウィンドウ起動前の post もキューに積まれ、起動後の最初の drain で配送されます。
pub fn post_event(view : Int, payload : Bytes) -> Result[Unit, Int] {
  let status = gpui_post_event_ffi(view, payload, payload.length())
  if status == 0 {
    Ok(())
  } else {
    Err(status)
  }
}

///|
/// `EVENT_ASYNC` ディスパッチ中に、そのペイロードを同期的にコピーして返します。
/// `token` / `len` は `dispatch` の `data_a` / `data_b` です。ペイロードは `dispatch`
/// が戻るまでの間だけ有効なので、ハンドラはこの呼び出しで即座にコピーしなければ
/// なりません（`EVENT_TEXT` と同じ契約）。`len == 0` のときは空の `Bytes` を返します。
pub fn copy_async_payload(token : Int, len : Int) -> Bytes {
  if len <= 0 {
    return b""
  }
  let buf = Bytes::make(len, b'\x00')
  let copied = gpui_event_copy_text_ffi(token, buf, len)
  if copied > 0 {
    buf[0:copied].to_owned()
  } else {
    b""
  }
}

// --- Diagnostics (issue #54, G21) ------------------------------------------

///|
/// `view` にコミット済みのツリーから、全テキストノードの内容を DFS pre-order で
/// 読み戻します（デバッグ用）。各ノードは `len u32 LE + utf8[len]` のレコードとして
/// 連結され、その全体を UTF-8 デコードした文字列を返します。失敗時は負の
/// `GPUI_STATUS_*` コードを `Err(status)` で返します。
pub fn debug_dump_text(view : Int) -> Result[String, Int] {
  // The dump is a sequence of `len u32 LE + utf8[len]` records; a committed
  // tree is tiny, so a generous fixed capacity avoids a size-query round trip.
  let cap = 65536
  let buf = Bytes::make(cap, b'\x00')
  let n = gpui_debug_dump_text_ffi(view, buf, cap)
  if n < 0 {
    Err(n)
  } else {
    Ok(@utf8.decode_lossy(buf[0:n]))
  }
}

// --- Cross-boundary ABI probe (issue #54, G23) ------------------------------

///|
/// Rust 側の `gpui_abi_probe` を呼び、`v` をそのまま返させます。MoonBit の `Int` と
/// Rust の `i32` が C 境界をまたいで同じ幅・符号で往復することを機械的に検証するための
/// identity echo です。`cmd/roundtrip` が境界値（`i32::MAX` / `i32::MIN` / 0 / -1）を送り、
/// ビルドのたびに不一致を検出します。
pub fn abi_probe(v : Int) -> Int {
  gpui_abi_probe_ffi(v)
}
