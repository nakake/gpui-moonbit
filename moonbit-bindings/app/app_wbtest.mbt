///|
let rebuild_calls : Array[Int] = [0]

///|
fn record_rebuild() -> Unit {
  rebuild_calls[0] = rebuild_calls[0] + 1
}

///|
test "rebuild gate runs only for changed events" {
  rebuild_calls[0] = 0
  assert_eq(rebuild_if_changed(0, record_rebuild), 0)
  assert_eq(rebuild_calls[0], 0)
  assert_eq(rebuild_if_changed(1, record_rebuild), 1)
  assert_eq(rebuild_calls[0], 1)
}

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
  match decode(999, 0, 0, 0) {
    Unknown => ()
    _ => fail("unknown event kind must decode to Unknown")
  }
}
