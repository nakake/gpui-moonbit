// High-level API for GPUI
// FFI declarations are auto-generated in gpui-bindings-ffi.mbt

pub type NodeHandle = Int

fn clamp_color_component(value : Int) -> Int {
  if value < 0 {
    0
  } else if value > 255 {
    255
  } else {
    value
  }
}

pub fn create_div() -> NodeHandle {
  gpui_create_div_ffi()
}

pub fn set_size(handle : NodeHandle, w : Float, h : Float) -> NodeHandle {
  gpui_set_size_ffi(handle, w, h)
  handle
}

/// Sets the background color, clamping each RGB component to the 0-255 range.
pub fn set_bg(handle : NodeHandle, r : Int, g : Int, b : Int) -> NodeHandle {
  gpui_set_bg_ffi(
    handle,
    clamp_color_component(r),
    clamp_color_component(g),
    clamp_color_component(b),
  )
  handle
}

pub fn set_flex_row(handle : NodeHandle) -> NodeHandle {
  gpui_set_flex_ffi(handle, 0)
  handle
}

pub fn set_flex_col(handle : NodeHandle) -> NodeHandle {
  gpui_set_flex_ffi(handle, 1)
  handle
}

pub fn set_center(handle : NodeHandle) -> NodeHandle {
  gpui_set_center_ffi(handle)
  handle
}

pub fn set_gap(handle : NodeHandle, gap : Float) -> NodeHandle {
  gpui_set_gap_ffi(handle, gap)
  handle
}

pub fn set_rounded(handle : NodeHandle, radius : Float) -> NodeHandle {
  gpui_set_rounded_ffi(handle, radius)
  handle
}

// MoonBit's native `String` is UTF-16 and not NUL-terminated, so it cannot be
// passed directly where C expects `const char *` (the first embedded NUL byte of
// an ASCII code unit would truncate it to a single character). Encode to UTF-8
// and append a NUL terminator so the Rust side can read the whole string via
// `CStr::from_ptr`.
fn to_cstring_bytes(text : String) -> Bytes {
  let utf8 = @utf8.encode(text)
  let buf = Buffer(size_hint=utf8.length() + 1)
  buf.write_bytes(utf8)
  buf.write_byte(0)
  buf.to_bytes()
}

/// Creates text with each RGB color component clamped to the 0-255 range.
pub fn create_text(text : String, r : Int, g : Int, b : Int, size : Float) -> NodeHandle {
  gpui_create_text_ffi(
    to_cstring_bytes(text),
    clamp_color_component(r),
    clamp_color_component(g),
    clamp_color_component(b),
    size,
  )
}

pub fn add_child(parent : NodeHandle, child : NodeHandle) -> NodeHandle {
  gpui_add_child_ffi(parent, child)
  parent
}

pub fn run_window(width : Float, height : Float) -> Unit {
  gpui_run_window_ffi(width, height)
}

pub fn set_on_click(handle : NodeHandle, click_id : Int) -> NodeHandle {
  gpui_set_on_click_ffi(handle, click_id)
  handle
}

pub fn reset() -> Unit {
  gpui_reset_ffi()
}
