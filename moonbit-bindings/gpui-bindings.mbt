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
/// A length-delimited command buffer describing one UI tree. Node creation
/// pushes a handle onto an internal stack (Rust-side); setters apply to the top
/// of the stack; `add_child` pops child then parent and re-pushes the parent;
/// `set_root` pops the root. All multi-byte values are little-endian. Submit
/// with `build_tree`.
pub struct CommandBuffer {
  buf : @buffer.Buffer
}

///|
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
/// Push a new div; it becomes the top of the stack.
pub fn CommandBuffer::div(self : CommandBuffer) -> Unit {
  self.op(OP_DIV)
}

///|
/// Push a new text node (RGB components clamped to 0-255); it becomes the top.
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
/// Set the size of the div on top of the stack.
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
/// Set the background color of the div on top of the stack (clamped to 0-255).
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
/// Lay out the div on top of the stack as a flex row.
pub fn CommandBuffer::set_flex_row(self : CommandBuffer) -> Unit {
  self.op(OP_SET_FLEX)
  self.buf.write_byte(b'\x00')
}

///|
/// Lay out the div on top of the stack as a flex column.
pub fn CommandBuffer::set_flex_col(self : CommandBuffer) -> Unit {
  self.op(OP_SET_FLEX)
  self.buf.write_byte(b'\x01')
}

///|
/// Center the children of the div on top of the stack.
pub fn CommandBuffer::set_center(self : CommandBuffer) -> Unit {
  self.op(OP_SET_CENTER)
}

///|
/// Set the gap of the div on top of the stack.
pub fn CommandBuffer::set_gap(self : CommandBuffer, gap : Float) -> Unit {
  self.op(OP_SET_GAP)
  self.buf.write_float_le(gap)
}

///|
/// Set the corner radius of the div on top of the stack.
pub fn CommandBuffer::set_rounded(self : CommandBuffer, radius : Float) -> Unit {
  self.op(OP_SET_ROUNDED)
  self.buf.write_float_le(radius)
}

///|
/// Make the div on top of the stack clickable; `click_id` is routed to
/// `dispatch` on click.
pub fn CommandBuffer::set_on_click(
  self : CommandBuffer,
  click_id : Int,
) -> Unit {
  self.op(OP_SET_ON_CLICK)
  self.buf.write_int_le(click_id)
}

///|
/// Set an explicit stable identity for the div on top of the stack, independent
/// of click routing. The key becomes the GPUI element id so stateful-element
/// identity survives rebuilds. Duplicate keys within one tree are rejected.
pub fn CommandBuffer::set_key(self : CommandBuffer, key : String) -> Unit {
  self.op(OP_SET_KEY)
  self.write_str(key)
}

///|
/// Set the uniform padding of the div on top of the stack.
pub fn CommandBuffer::set_padding(
  self : CommandBuffer,
  padding : Float,
) -> Unit {
  self.op(OP_SET_PADDING)
  self.buf.write_float_le(padding)
}

///|
/// Set the border of the div on top of the stack: a uniform width plus an RGB
/// color (clamped to 0-255). A non-positive width renders no border.
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
/// Attach the node on top of the stack (child) to the one below it (parent).
/// The parent stays on top so further children can be attached.
pub fn CommandBuffer::add_child(self : CommandBuffer) -> Unit {
  self.op(OP_ADD_CHILD)
}

///|
/// Designate the node on top of the stack as the tree root.
pub fn CommandBuffer::set_root(self : CommandBuffer) -> Unit {
  self.op(OP_SET_ROOT)
}

///|
/// Serialize the accumulated commands to their wire bytes.
pub fn CommandBuffer::to_bytes(self : CommandBuffer) -> Bytes {
  self.buf.to_bytes()
}

///|
/// Build and commit the tree for `view` from one command buffer, replacing the
/// previously committed tree. This is the single FFI crossing for the whole
/// tree. Returns `Err(status)` with a negative `GPUI_STATUS_*` code on failure;
/// the previously committed tree is left untouched.
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
/// Open a GPUI window rendering the committed tree for `view` (index into the
/// Rust-side view slots set by `build_tree`) and block in the event loop.
/// Returns `Err(status)` if the window could not be created or the event loop
/// panicked.
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
