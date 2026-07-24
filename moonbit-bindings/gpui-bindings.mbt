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
