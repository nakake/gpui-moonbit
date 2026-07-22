// The rebuild gate (rebuild only when changed == 1) is now inlined in
// `dispatch`, which transitively references Rust FFI (`gpui_build_tree_ffi`,
// `gpui_event_copy_text_ffi`) and cannot run under `moon test`. The gate is
// verified by the CI linked-binary roundtrip test (cmd/roundtrip) and the
// full build driver's headless round-trip.

///|
test "event application preserves unknown events" {
  count[0] = 9
  assert_eq(apply_event(Unknown), 0)
  assert_eq(apply_event(Click(999)), 0)
  assert_eq(apply_event(Key(0, 0)), 0)
  assert_eq(count[0], 9)
}

///|
test "click handlers report state changes" {
  count[0] = 0
  assert_eq(on_click(BTN_DECREMENT), 1)
  assert_eq(count[0], -1)
  assert_eq(on_click(BTN_INCREMENT), 1)
  assert_eq(count[0], 0)
  assert_eq(on_click(BTN_INCREMENT_10), 1)
  assert_eq(count[0], 10)
}

///|
test "click reset reports only real changes" {
  count[0] = 5
  assert_eq(on_click(BTN_RESET), 1)
  assert_eq(count[0], 0)
  assert_eq(on_click(BTN_RESET), 0)
  assert_eq(count[0], 0)
}

///|
test "unknown click is unchanged" {
  count[0] = 7
  assert_eq(on_click(999), 0)
  assert_eq(count[0], 7)
}

///|
test "key handlers report state changes" {
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
  // NOTE: decode() is not called here because it transitively references
  // gpui_event_copy_text (Rust FFI), which is unavailable in moon test.
  // The version handshake is verified by the CI linked-binary run.
}

///|
test "named key handlers report state changes" {
  count[0] = 0
  assert_eq(on_named_key(@username/gpui-bindings.KEY_ENTER, 0), 1)
  assert_eq(count[0], 1)
  assert_eq(on_named_key(@username/gpui-bindings.KEY_UP, 0), 1)
  assert_eq(count[0], 2)
  assert_eq(on_named_key(@username/gpui-bindings.KEY_DOWN, 0), 1)
  assert_eq(count[0], 1)
  assert_eq(on_named_key(@username/gpui-bindings.KEY_ESCAPE, 0), 1)
  assert_eq(count[0], 0)
  assert_eq(on_named_key(@username/gpui-bindings.KEY_ESCAPE, 0), 0) // already 0
}

///|
test "unknown named key is unchanged" {
  count[0] = 5
  assert_eq(on_named_key(99, 0), 0)
  assert_eq(count[0], 5)
}
