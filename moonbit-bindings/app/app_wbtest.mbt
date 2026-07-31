// Whitebox tests for the Counter app's pure logic. `dispatch` itself
// transitively references Rust FFI (`gpui_build_tree_ffi`,
// `gpui_event_copy_text_ffi`) and cannot run under `moon test`; the registry
// routing it performs is covered by the library's `handlers_wbtest.mbt`, and
// the full envelope → rebuild path by the build driver's linked round-trip.

///|
test "registered click handlers mutate count" {
  count[0] = 0
  handlers.dispatch(Click(btn_decrement), 0)
  assert_eq(count[0], -1)
  handlers.dispatch(Click(btn_increment), 0)
  assert_eq(count[0], 0)
  handlers.dispatch(Click(btn_increment_10), 0)
  assert_eq(count[0], 10)
}

///|
test "reset handler zeroes count" {
  count[0] = 5
  handlers.dispatch(Click(btn_reset), 0)
  assert_eq(count[0], 0)
  // Idempotent: resetting an already-zero count stays zero.
  handlers.dispatch(Click(btn_reset), 0)
  assert_eq(count[0], 0)
}

///|
test "unknown click id leaves count untouched" {
  count[0] = 7
  handlers.dispatch(Click(999), 0)
  assert_eq(count[0], 7)
}

///|
test "key handler mutates count" {
  count[0] = 0
  assert_eq(on_key(KEY_K, 0), 1)
  assert_eq(count[0], 1)
  assert_eq(on_key(KEY_J, 0), 1)
  assert_eq(count[0], 0)
  count[0] = 5
  assert_eq(on_key(KEY_R, 0), 1)
  assert_eq(count[0], 0)
  assert_eq(on_key(KEY_R, 0), 0)
}

///|
test "unknown key and event are unchanged" {
  count[0] = 11
  assert_eq(on_key(0, 0), 0)
  assert_eq(count[0], 11)
  // NOTE: decode_event() is not called here because it transitively references
  // gpui_event_copy_text (Rust FFI), which is unavailable in moon test. The
  // version handshake is verified by the CI linked-binary run.
}

///|
test "named key handler mutates count" {
  count[0] = 0
  assert_eq(on_named_key(@nakake/gpui-bindings.KEY_ENTER, 0), 1)
  assert_eq(count[0], 1)
  assert_eq(on_named_key(@nakake/gpui-bindings.KEY_UP, 0), 1)
  assert_eq(count[0], 2)
  assert_eq(on_named_key(@nakake/gpui-bindings.KEY_DOWN, 0), 1)
  assert_eq(count[0], 1)
  assert_eq(on_named_key(@nakake/gpui-bindings.KEY_ESCAPE, 0), 1)
  assert_eq(count[0], 0)
  assert_eq(on_named_key(@nakake/gpui-bindings.KEY_ESCAPE, 0), 0) // already 0
}

///|
test "unknown named key is unchanged" {
  count[0] = 5
  assert_eq(on_named_key(99, 0), 0)
  assert_eq(count[0], 5)
}

///|
test "text handler parses digit strings" {
  count[0] = 0
  assert_eq(on_text("42"), 1)
  assert_eq(count[0], 42)
  assert_eq(on_text("42"), 0) // no change
  assert_eq(on_text("abc"), 0) // non-digit ignored
  assert_eq(count[0], 42)
  assert_eq(on_text(""), 0)
}
