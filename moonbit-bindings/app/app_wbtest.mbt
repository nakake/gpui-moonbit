// Whitebox tests for the Counter app's pure logic. `dispatch` itself
// transitively references Rust FFI (`gpui_build_tree_ffi`,
// `gpui_event_copy_text_ffi`) and cannot run under `moon test`; the framework
// glue it delegates to (`framework_dispatch`) is covered by the library's
// `signal_wbtest.mbt`, and the full envelope → rebuild path by the build
// driver's linked round-trip.


///|
test "app-level key handlers are registered in the registry" {
  // Regression guard (issue #86): the key/named-key/text handlers must survive
  // dead-code elimination. If their registration is dropped, dispatching a Key
  // event through the registry leaves `count` untouched.
  count.set(store, 100)
  handlers.dispatch(Key(KEY_K, 0), 0)
  assert_eq(count.get(store), 101)
}
///|
test "registered click handlers mutate count" {
  count.set(store, 0)
  handlers.dispatch(Click(btn_decrement.to_int()), 0)
  assert_eq(count.get(store), -1)
  handlers.dispatch(Click(btn_increment.to_int()), 0)
  assert_eq(count.get(store), 0)
  handlers.dispatch(Click(btn_increment_10.to_int()), 0)
  assert_eq(count.get(store), 10)
}

///|
test "reset handler zeroes count" {
  count.set(store, 5)
  handlers.dispatch(Click(btn_reset.to_int()), 0)
  assert_eq(count.get(store), 0)
}

///|
test "unknown click id leaves count untouched" {
  count.set(store, 7)
  handlers.dispatch(Click(999), 0)
  assert_eq(count.get(store), 7)
}

///|
test "key handler mutates count" {
  count.set(store, 0)
  on_key(KEY_K, 0)
  assert_eq(count.get(store), 1)
  on_key(KEY_J, 0)
  assert_eq(count.get(store), 0)
  count.set(store, 5)
  on_key(KEY_R, 0)
  assert_eq(count.get(store), 0)
}

///|
test "unknown key leaves count untouched" {
  count.set(store, 11)
  on_key(0, 0)
  assert_eq(count.get(store), 11)
  // NOTE: decode_event() is not called here because it transitively references
  // gpui_event_copy_text (Rust FFI), which is unavailable in moon test. The
  // version handshake is verified by the CI linked-binary run.
}

///|
test "named key handler mutates count" {
  count.set(store, 0)
  on_named_key(@nakake/gpui-bindings.KEY_ENTER, 0)
  assert_eq(count.get(store), 1)
  on_named_key(@nakake/gpui-bindings.KEY_UP, 0)
  assert_eq(count.get(store), 2)
  on_named_key(@nakake/gpui-bindings.KEY_DOWN, 0)
  assert_eq(count.get(store), 1)
  on_named_key(@nakake/gpui-bindings.KEY_ESCAPE, 0)
  assert_eq(count.get(store), 0)
}

///|
test "unknown named key leaves count untouched" {
  count.set(store, 5)
  on_named_key(99, 0)
  assert_eq(count.get(store), 5)
}

///|
test "text handler parses digit strings" {
  count.set(store, 0)
  on_text("42")
  assert_eq(count.get(store), 42)
  on_text("abc") // non-digit ignored
  assert_eq(count.get(store), 42)
  on_text("")
  assert_eq(count.get(store), 42)
}

///|
test "text handler rejects digit runs that would overflow i32" {
  count.set(store, 0)
  // 0x7FFFFFFF = 2147483647 fits; one digit longer must be rejected (no wrap).
  on_text("2147483647")
  assert_eq(count.get(store), 2147483647)
  count.set(store, 5)
  on_text("2147483648") // i32::MAX + 1 → rejected, count unchanged
  assert_eq(count.get(store), 5)
  on_text("99999999999") // 11 digits → rejected
  assert_eq(count.get(store), 5)
}

///|
test "submit handler parses digits and sets count" {
  // `input_text` / `input_set_text` are Rust FFI and cannot run under
  // `moon test`, so the pull/clear half of `on_submit_input` is covered by
  // the linked round-trip (cmd/roundtrip). The parse half is pure:
  count.set(store, 0)
  match parse_digits("42") {
    Some(value) => count.set(store, value)
    None => ()
  }
  assert_eq(count.get(store), 42)
}

///|
test "submit parser rejects empty, non-digit, and overflowing input" {
  assert_eq(parse_digits(""), None)
  assert_eq(parse_digits("12a"), None)
  assert_eq(parse_digits("2147483647"), Some(2147483647))
  assert_eq(parse_digits("2147483648"), None) // i32::MAX + 1
  assert_eq(parse_digits("99999999999"), None)
}
