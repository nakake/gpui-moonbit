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

///|
/// Rust 側の retained node tree のノードを指すハンドルです。現行の高水準 API はノードをスタックで暗黙に管理するため、この型を直接取り回す必要はありません。
pub type NodeHandle = Int

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
/// 新しいテキストノードをプッシュします（RGB 各成分は 0–255 にクランプ）。プッシュしたノードはスタックトップになります。
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
/// スタックトップの div の背景色を設定します（RGB 各成分は 0–255 にクランプ）。
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
/// を取ります。太さが 0 以下の場合は枠線を描画しません。
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
