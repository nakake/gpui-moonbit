// Minimal consumer smoke test (issue #103).
//
// This module depends on nakake/gpui-bindings by path and imports the
// link-only package, so building it exercises the whole prebuild path:
// build.py runs, cargo builds the Rust staticlib, and the LinkConfig it
// emits has to be good enough for the platform linker.
//
// It must actually *call* into the staticlib — a program that only imports
// the bindings would link even with broken flags, because nothing pulls an
// object out of the archive.
//
// Headless, so no window is opened: input_text against an unrealized view
// returns GPUI_STATUS_INVALID_HANDLE (-1) instead of a string.

// A dispatch of the consumer's own. The library ships no app any more (RFC
// 0004), so writing one here is the point: it is what a third party has to do,
// and the check below proves the registration actually reached the entry point
// Rust links against.

///|
let dispatched : Ref[Int] = { val: 0 }

///|
fn dispatch(
  _version : Int,
  _kind : Int,
  _view : Int,
  _data_a : Int,
  _data_b : Int,
) -> Int {
  dispatched.val = dispatched.val + 1
  0 // nothing to redraw: this consumer never opens a window
}

///|
fn main {
  // Register a dispatch so the staticlib's mb_dispatch reference resolves to
  // the library's entry point (RFC 0004). No `_keep` binding: registering is
  // what retains `dispatch_entry` through dead-code elimination.
  @nakake/gpui-bindings.register_dispatch(dispatch)

  // The registered closure must be what `dispatch_entry` delegates to.
  if @nakake/gpui-bindings.dispatch_entry(
      @nakake/gpui-bindings.ABI_VERSION,
      @nakake/gpui-bindings.EVENT_CLICK,
      0,
      1,
      0,
    ) !=
    0 {
    abort("dispatch_entry did not return the registered dispatch's value")
  }
  if dispatched.val != 1 {
    abort("registered dispatch ran \{dispatched.val} times, want 1")
  }

  // Serialize a small tree — pure MoonBit, no FFI yet.
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div()
  cb.text("consumer smoke", 255, 255, 255, 16.0)
  cb.add_child()
  cb.set_root()
  let wire = cb.to_bytes()
  if wire.length() == 0 {
    abort("CommandBuffer produced an empty wire buffer")
  }

  // Cross the FFI boundary: this is what forces the linker to resolve
  // gpui_sys and every native library the prebuild reported.
  match @nakake/gpui-bindings.input_text(0, 0) {
    Ok(text) => abort("input_text unexpectedly succeeded headless: '\{text}'")
    Err(status) =>
      if status != -1 {
        abort("input_text returned \{status}, want -1 (INVALID_HANDLE)")
      }
  }
  println("PASS: prebuild consumption verified (\{wire.length()} bytes serialized)")
}
