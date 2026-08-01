// Whitebox tests for signals and the store's dirty tracking (RFC 0001 §3.4).
// Pure MoonBit. `framework_dispatch` itself transitively references Rust FFI
// (`gpui_event_copy_text` via `decode_event`) and cannot run under
// `moon test`; its gate (rebuild only on dirt, stale-version rejection,
// no-op events returning 0) is verified by the build driver's linked
// round-trip (cmd/roundtrip dispatch smoke).

///|
test "signal set dirties the store" {
  let s = Store::new()
  let cell : CellId[Int] = s.new_cell(0)
  let sig : Signal[Int] = s.signal(cell)
  s.begin_dirty_tracking()
  assert_eq(s.has_dirty(), false)
  sig.set(s, 5)
  assert_eq(s.has_dirty(), true)
  assert_eq(sig.get(s), 5)
}

///|
test "signal set goes through store dirty tracking" {
  // A signal write and a direct store write are the same dirt source.
  let s = Store::new()
  let a : CellId[Int] = s.new_cell(0)
  let b : CellId[Int] = s.new_cell(0)
  let sig : Signal[Int] = s.signal(a)
  s.begin_dirty_tracking()
  sig.set(s, 1)
  s.set(b, 2)
  assert_eq(s.has_dirty(), true)
  assert_eq(sig.get(s), 1)
  assert_eq(s.get(b), 2)
}

///|
test "begin_dirty_tracking clears previous dirt" {
  let s = Store::new()
  let cell : CellId[Int] = s.new_cell(0)
  s.set(cell, 1)
  assert_eq(s.has_dirty(), true)
  s.begin_dirty_tracking()
  assert_eq(s.has_dirty(), false)
}

///|
test "reads do not dirty the store" {
  let s = Store::new()
  let cell : CellId[Int] = s.new_cell(3)
  let sig : Signal[Int] = s.signal(cell)
  s.begin_dirty_tracking()
  ignore(sig.get(s))
  ignore(s.get(cell))
  assert_eq(s.has_dirty(), false)
}
