// Whitebox tests for the Counter app's pure logic. `dispatch` itself
// transitively references Rust FFI (`gpui_build_tree_ffi`,
// `gpui_event_copy_text_ffi`) and cannot run under `moon test`; the framework
// glue it delegates to (`framework_dispatch`) is covered by the library's
// `signal_wbtest.mbt`, and the full envelope → rebuild path by the build
// driver's linked round-trip.
//
// The rebuild's fallback decision (issue #10: incremental `update_text` first,
// full `build_tree` on failure) is the exception: `update_view_with` takes both
// effects as arguments, so the tests below drive every branch with stubs and
// never reach a FFI symbol.

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

// --- Rebuild fallback (issue #10) -------------------------------------------

///|
test "a successful incremental update does not rebuild the tree" {
  let incremental_views = []
  let rebuilds = []
  let r = update_view_with(
    7,
    fn(v) {
      incremental_views.push(v)
      Ok(())
    },
    fn(v) {
      rebuilds.push(v)
      Ok(())
    },
  )
  assert_eq(r, Ok(()))
  assert_eq(incremental_views, [7])
  assert_eq(rebuilds, []) // the whole point of the incremental path
}

///|
test "a failed incremental update falls back to the full rebuild" {
  let rebuilds = []
  // KEY_NOT_FOUND is what `update_text` returns when the tree is not committed
  // yet or the keyed text node is gone — the documented fallback trigger.
  let r = update_view_with(3, fn(_v) { Err(-10) }, fn(v) {
    rebuilds.push(v)
    Ok(())
  })
  assert_eq(r, Ok(()))
  assert_eq(rebuilds, [3]) // same view, not a hardcoded slot
}

///|
test "the fallback surfaces the rebuild's own failure" {
  let r = update_view_with(0, fn(_v) { Err(-10) }, fn(_v) { Err(-6) })
  assert_eq(r, Err(-6)) // not the incremental path's -10
}

///|
test "both rebuild paths render the same count label" {
  // `update_text` writes `count_label` directly while `build_tree` renders it
  // through `counter_card`; a drift between the two would make the display
  // flip between formats on every rebuild.
  assert_eq(count_label(0), "Count: 0")
  assert_eq(count_label(-12), "Count: -12")
}
