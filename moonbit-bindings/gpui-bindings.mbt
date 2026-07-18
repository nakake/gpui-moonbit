// High-level API for GPUI
// FFI declarations are auto-generated in gpui-bindings-ffi.mbt

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

///|
pub fn create_div() -> NodeHandle {
  gpui_create_div_ffi()
}

///|
pub fn set_size(handle : NodeHandle, w : Float, h : Float) -> NodeHandle {
  ignore(gpui_set_size_ffi(handle, w, h))
  handle
}

///|
/// Sets the background color, clamping each RGB component to the 0-255 range.
pub fn set_bg(handle : NodeHandle, r : Int, g : Int, b : Int) -> NodeHandle {
  ignore(
    gpui_set_bg_ffi(
      handle,
      clamp_color_component(r),
      clamp_color_component(g),
      clamp_color_component(b),
    ),
  )
  handle
}

///|
pub fn set_flex_row(handle : NodeHandle) -> NodeHandle {
  ignore(gpui_set_flex_ffi(handle, 0))
  handle
}

///|
pub fn set_flex_col(handle : NodeHandle) -> NodeHandle {
  ignore(gpui_set_flex_ffi(handle, 1))
  handle
}

///|
pub fn set_center(handle : NodeHandle) -> NodeHandle {
  ignore(gpui_set_center_ffi(handle))
  handle
}

///|
pub fn set_gap(handle : NodeHandle, gap : Float) -> NodeHandle {
  ignore(gpui_set_gap_ffi(handle, gap))
  handle
}

///|
pub fn set_rounded(handle : NodeHandle, radius : Float) -> NodeHandle {
  ignore(gpui_set_rounded_ffi(handle, radius))
  handle
}

// MoonBit's native `String` is UTF-16, so encode it to UTF-8 for the byte-based
// Rust FFI. The explicit byte length means no NUL terminator is needed.

///|
fn to_utf8_bytes(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// Creates text with each RGB color component clamped to the 0-255 range.
pub fn create_text(
  text : String,
  r : Int,
  g : Int,
  b : Int,
  size : Float,
) -> NodeHandle {
  let utf8 = to_utf8_bytes(text)
  gpui_create_text_ffi(
    utf8,
    utf8.length(),
    clamp_color_component(r),
    clamp_color_component(g),
    clamp_color_component(b),
    size,
  )
}

///|
pub fn add_child(parent : NodeHandle, child : NodeHandle) -> NodeHandle {
  ignore(gpui_add_child_ffi(parent, child))
  parent
}

///|
pub fn run_window(width : Float, height : Float) -> Unit {
  ignore(gpui_run_window_ffi(width, height))
}

///|
pub fn set_on_click(handle : NodeHandle, click_id : Int) -> NodeHandle {
  ignore(gpui_set_on_click_ffi(handle, click_id))
  handle
}

///|
pub fn reset() -> Unit {
  ignore(gpui_reset_ffi())
}
