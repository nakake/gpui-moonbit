// Whitebox tests for the typed handler registry (RFC 0001 §3.2). Pure MoonBit:
// the registry holds closures and dispatches decoded events, no FFI involved.

///|
test "on_click issues distinct ids and dispatches to the registered handler" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.on_click(fn(view) { log.push(100 + view) })
  let b = r.on_click(fn(view) { log.push(200 + view) })
  if a == b {
    fail("ids must be distinct")
  }
  r.dispatch(Click(a), 7)
  r.dispatch(Click(b), 3)
  assert_eq(log, [107, 203])
}

///|
test "unknown click id is a no-op" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  ignore(r.on_click(fn(_) { log.push(1) }))
  r.dispatch(Click(999), 0)
  assert_eq(log, [])
}

///|
test "key handlers fan out in registration order" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  ignore(r.on_key(fn(code, mods) { log.push(code + mods) }))
  ignore(r.on_key(fn(code, _) { log.push(code) }))
  r.dispatch(Key(10, 5), 0)
  assert_eq(log, [15, 10])
}

///|
test "named key handlers fan out in registration order" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  ignore(r.on_named_key(fn(id, mods) { log.push(id * 10 + mods) }))
  r.dispatch(NamedKey(4, 2), 0)
  assert_eq(log, [42])
}

///|
test "text handlers receive the decoded string" {
  let r = HandlerRegistry::new()
  let seen : Array[String] = []
  ignore(r.on_text(fn(t) { seen.push(t) }))
  r.dispatch(Text("hello"), 0)
  assert_eq(seen, ["hello"])
}

///|
test "unknown events dispatch nothing" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  ignore(r.on_click(fn(_) { log.push(1) }))
  ignore(r.on_key(fn(_, _) { log.push(2) }))
  r.dispatch(Unknown, 0)
  assert_eq(log, [])
}

///|
test "ids are shared across handler kinds" {
  let r = HandlerRegistry::new()
  let a = r.on_click(fn(_) {})
  let b = r.on_key(fn(_, _) {})
  let c = r.on_named_key(fn(_, _) {})
  let d = r.on_text(fn(_) {})
  assert_eq([a, b, c, d], [1, 2, 3, 4])
}
