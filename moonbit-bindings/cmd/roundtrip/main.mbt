// Headless round-trip test (issue #34): MoonBit → C → Rust → C → MoonBit.
//
// Builds a tree with edge-case text (NUL byte, multibyte UTF-8, 4-byte emoji),
// submits via gpui_build_tree, reads back via gpui_debug_dump_text, and
// compares the dumped bytes against the expected encoding.
// Normal completion = pass (exit 0); abort = non-zero exit.

// Direct FFI declarations (not in root package → moon test unaffected).
///|
#borrow(ptr)
extern "C" fn gpui_build_tree_ffi(view : Int, ptr : Bytes, len : Int) -> Int = "gpui_build_tree"

///|
#borrow(buf)
extern "C" fn gpui_debug_dump_text_ffi(
  view : Int,
  buf : Bytes,
  len : Int,
) -> Int = "gpui_debug_dump_text"

// Cross-boundary ABI probe (issue #54, G23): echo i32 boundary values through
// Rust and back. MoonBit native `Int` must be ABI-compatible with Rust `i32`
// for the whole bridge; a width/sign mismatch corrupts silently, so we fail
// the build here instead.

///|
extern "C" fn gpui_abi_probe_ffi(value : Int) -> Int = "gpui_abi_probe"

///|
fn main {
  // Register this smoke's own dispatch (smoke_app.mbt) into the library-owned
  // entry point Rust links (RFC 0004). The smoke below then drives
  // `dispatch_entry`, so the registration path itself is covered by the linked
  // run, not just the slot's unit tests.
  @nakake/gpui-bindings.register_dispatch(app_dispatch)

  // Edge-case text: NUL byte, multibyte UTF-8 (hiragana), 4-byte emoji.
  let texts = ["A\u{0}あ", "🎉"]

  // Build tree: div { text(t0), text(t1) }
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div()
  for t in texts {
    cb.text(t, 255, 255, 255, 16.0)
    cb.add_child()
  }
  cb.set_root()

  // Submit via FFI
  let wire = cb.to_bytes()
  let status = gpui_build_tree_ffi(0, wire, wire.length())
  if status != 0 {
    abort("gpui_build_tree returned \{status}")
  }

  // Read back via FFI
  let cap = 1024
  let buf = Bytes::make(cap, b'\x00')
  let n = gpui_debug_dump_text_ffi(0, buf, cap)
  if n < 0 {
    abort("gpui_debug_dump_text returned \{n}")
  }

  // Build expected: len u32 LE + utf8 for each text, DFS pre-order
  let expected = @buffer.Buffer()
  for t in texts {
    let utf8 = @utf8.encode(t)
    expected.write_uint_le(utf8.length().reinterpret_as_uint())
    expected.write_bytes(utf8.view())
  }
  let expected_bytes = expected.to_bytes()

  // Compare
  if n != expected_bytes.length() {
    abort("length mismatch: got \{n}, want \{expected_bytes.length()}")
  }
  let got : BytesView = buf[0:n]
  let want : BytesView = expected_bytes.view()
  let mut i = 0
  while i < n {
    if got[i] != want[i] {
      abort("byte mismatch at offset \{i}")
    }
    i = i + 1
  }

  // Cross-boundary ABI probe (issue #54, G23): i32 boundary values must echo
  // back unchanged. 0x7FFFFFFF = i32::MAX, -0x80000000 = i32::MIN.
  let probe_values = [0x7FFFFFFF, -0x80000000, 0, -1, 42]
  for v in probe_values {
    let echoed = gpui_abi_probe_ffi(v)
    if echoed != v {
      abort("abi probe mismatch: sent \{v}, got \{echoed}")
    }
  }
  println("PASS: abi probe verified (\{probe_values.length()} values)")

  // Dispatch smoke test (RFC 0001): exercise the real linked `dispatch_entry`
  // symbol end to end — registry routing, the framework's dirty gate, the
  // stale-version rejection, and the committed state. The tree committed
  // above has no keyed count label, so the first state-changing dispatch
  // falls back from `update_text` to a full `build_tree` (which commits the
  // smoke app's tree) and returns 1; a stale ABI version must return 0 without
  // touching anything; a key event then updates the now-present count label
  // in place and returns 1.
  let changed_click = @nakake/gpui-bindings.dispatch_entry(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_CLICK,
    0,
    increment_handler_id(), // 実 id（登録順に依存するためハードコードしない）
    0,
  )
  if changed_click != 1 {
    abort("dispatch(click) returned \{changed_click}, want 1")
  }
  // The click rebuilt and committed the counter tree: its texts must now be
  // readable, with the count label at 1.
  let after_click = match gpui_debug_dump_text_ffi(0, buf, cap) {
    m if m < 0 => abort("dump after click failed: \{m}")
    m => @utf8.decode_lossy(buf[0:m])
  }
  if !after_click.contains("Count: 1") {
    abort("after click, dump lacks 'Count: 1': \{after_click}")
  }
  // A click with no registered handler must not rebuild (dirty gate): the
  // committed tree is unchanged and dispatch returns 0.
  let changed_noop = @nakake/gpui-bindings.dispatch_entry(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_CLICK,
    0,
    999, // no handler registered for this id
    0,
  )
  if changed_noop != 0 {
    abort("dispatch(noop click) returned \{changed_noop}, want 0")
  }
  let after_noop = match gpui_debug_dump_text_ffi(0, buf, cap) {
    m if m < 0 => abort("dump after noop failed: \{m}")
    m => @utf8.decode_lossy(buf[0:m])
  }
  if !after_noop.contains("Count: 1") {
    abort("after noop, dump changed unexpectedly: \{after_noop}")
  }
  let changed_stale = @nakake/gpui-bindings.dispatch_entry(
    @nakake/gpui-bindings.ABI_VERSION + 1,
    @nakake/gpui-bindings.EVENT_CLICK,
    0,
    increment_handler_id(),
    0,
  )
  if changed_stale != 0 {
    abort("dispatch(stale) returned \{changed_stale}, want 0")
  }
  let changed_key = @nakake/gpui-bindings.dispatch_entry(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_KEY,
    0,
    107, // 'k' → +1
    0,
  )
  if changed_key != 1 {
    abort("dispatch(key) returned \{changed_key}, want 1")
  }
  // The key event updated the count label in place (update_text path): the
  // committed tree now reads 2.
  let after_key = match gpui_debug_dump_text_ffi(0, buf, cap) {
    m if m < 0 => abort("dump after key failed: \{m}")
    m => @utf8.decode_lossy(buf[0:m])
  }
  if !after_key.contains("Count: 2") {
    abort("after key, dump lacks 'Count: 2': \{after_key}")
  }
  println("PASS: dispatch smoke verified (click/noop/stale/key, state 1→2)")

  // Text-input smoke (RFC 0003): the three new C exports must link and behave
  // across the boundary. The editable model is created at first render
  // (run_window), so headlessly the input_id is still unknown: the pull ABI
  // must propagate GPUI_STATUS_INVALID_HANDLE (-1) cleanly, not crash.
  let input_id = prompt_input_id()
  match @nakake/gpui-bindings.input_text(0, input_id) {
    Ok(t) => abort("input_text unexpectedly succeeded headless: '\{t}'")
    Err(s) =>
      if s != -1 {
        abort("input_text returned \{s}, want -1 (INVALID_HANDLE)")
      }
  }
  match @nakake/gpui-bindings.input_set_text(0, input_id, "42") {
    Ok(_) => abort("input_set_text unexpectedly succeeded headless")
    Err(s) =>
      if s != -1 {
        abort("input_set_text returned \{s}, want -1 (INVALID_HANDLE)")
      }
  }
  // EVENT_INPUT_SUBMIT decodes and routes to the registered handler; its pull
  // fails headless, so no state changes and dispatch returns 0 (dirty gate).
  let changed_submit = @nakake/gpui-bindings.dispatch_entry(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_INPUT_SUBMIT,
    0,
    input_id,
    0,
  )
  if changed_submit != 0 {
    abort(
      "dispatch(submit) returned \{changed_submit}, want 0 (pull fails headless)",
    )
  }
  println(
    "PASS: input smoke verified (pull ABI links, submit routes, headless -1)",
  )

  // Scroll-feedback smoke (issue #89): the pull export must link and behave
  // across the boundary. Nothing has painted headlessly, so the mirror is
  // empty: an unknown pair must propagate GPUI_STATUS_KEY_NOT_FOUND (-10) and
  // an invalid view GPUI_STATUS_INVALID_HANDLE (-1), not crash. EVENT_SCROLL
  // decodes and routes; with no handler registered dispatch returns 0.
  match @nakake/gpui-bindings.scroll_state(0, 12345) {
    Ok(_) => abort("scroll_state unexpectedly succeeded headless")
    Err(s) =>
      if s != -10 {
        abort("scroll_state returned \{s}, want -10 (KEY_NOT_FOUND)")
      }
  }
  match @nakake/gpui-bindings.scroll_state(-1, 1) {
    Ok(_) => abort("scroll_state(-1) unexpectedly succeeded")
    Err(s) =>
      if s != -1 {
        abort("scroll_state(-1) returned \{s}, want -1 (INVALID_HANDLE)")
      }
  }
  let changed_scroll = @nakake/gpui-bindings.dispatch_entry(
    @nakake/gpui-bindings.ABI_VERSION,
    @nakake/gpui-bindings.EVENT_SCROLL,
    0,
    12345, // no handler registered for this scroll_id
    0,
  )
  if changed_scroll != 0 {
    abort("dispatch(scroll) returned \{changed_scroll}, want 0 (no handler)")
  }
  println("PASS: scroll smoke verified (pull ABI links, headless -10/-1)")

  println("PASS: round-trip verified (\{n} bytes)")
}
