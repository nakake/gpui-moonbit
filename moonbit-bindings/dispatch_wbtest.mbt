// Whitebox tests for the dispatch registration slot (RFC 0004, issue #125).
// Pure MoonBit: the slot and `dispatch_entry` touch no FFI, so the delegation,
// the last-wins rule, and the unregistered default all run under `moon test`.
// What cannot run here is the link-time half — that Rust actually resolves
// `dispatch_entry`'s mangled symbol — which the build driver's [2/5] extraction
// and cmd/roundtrip's dispatch smoke cover.
//
// These tests mutate the module-global slot. That is by design (last-wins IS the
// documented reset mechanism); the default handler is therefore exercised by
// calling `no_dispatch` directly rather than by depending on test order.

///|
test "dispatch_entry delegates all five slots and the return value" {
  let seen : Ref[Array[Int]] = { val: [] }
  register_dispatch(fn(version, kind, view, data_a, data_b) {
    seen.val = [version, kind, view, data_a, data_b]
    1
  })
  assert_eq(dispatch_entry(4, 2, 7, 100, 200), 1)
  assert_eq(seen.val, [4, 2, 7, 100, 200])
}

///|
test "re-registration is last-wins" {
  register_dispatch(fn(_v, _k, _view, _a, _b) { 1 })
  assert_eq(dispatch_entry(4, 1, 0, 0, 0), 1)
  register_dispatch(fn(_v, _k, _view, _a, _b) { 0 })
  assert_eq(dispatch_entry(4, 1, 0, 0, 0), 0)
}

///|
test "the unregistered default reports no change" {
  // 0 = "nothing changed": Rust reads the return value as a redraw flag only, so
  // a program that never registered a dispatch stays linkable and runnable.
  // The once-flag is pre-armed so this case stays quiet; the warning itself is
  // the next test's subject.
  warned_unregistered.val = true
  assert_eq(no_dispatch(ABI_VERSION, EVENT_CLICK, 0, 1, 0), 0)
}

///|
test "the unregistered default warns exactly once" {
  // Each test sets the flag itself, so neither depends on the order they run in.
  // The one warning line this emits into `moon test` output is expected.
  warned_unregistered.val = false
  ignore(no_dispatch(ABI_VERSION, EVENT_CLICK, 0, 1, 0))
  assert_eq(warned_unregistered.val, true)
  // A second event must not warn again — a per-event line would flood a
  // streaming app.
  ignore(no_dispatch(ABI_VERSION, EVENT_ASYNC, 0, 0, 0))
  assert_eq(warned_unregistered.val, true)
}
