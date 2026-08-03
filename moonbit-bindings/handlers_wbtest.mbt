// Whitebox tests for the typed handler registry (RFC 0001 §3.2). Pure MoonBit:
// the registry holds closures and dispatches decoded events, no FFI involved.

///|
test "on_click issues distinct ids and dispatches to the registered handler" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.on_click(fn(view) { log.push(100 + view) })
  let b = r.on_click(fn(view) { log.push(200 + view) })
  if a.to_int() == b.to_int() {
    fail("ids must be distinct")
  }
  r.dispatch(Click(a.to_int()), 7)
  r.dispatch(Click(b.to_int()), 3)
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
test "new_input_id issues distinct ids sharing the handler counter" {
  let r = HandlerRegistry::new()
  let click = r.on_click(fn(_) {  }).to_int()
  let a = r.new_input_id().to_int()
  let b = r.new_input_id().to_int()
  // Ids come off one shared counter: click took 1, the inputs take 2 and 3.
  assert_eq([click, a, b], [1, 2, 3])
  if a == b {
    fail("input ids must be distinct")
  }
}

///|
test "input changed handlers dispatch by input_id only" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.new_input_id()
  let b = r.new_input_id()
  r.on_input_changed(a, fn(view) { log.push(100 + view) })
  r.on_input_changed(b, fn(view) { log.push(200 + view) })
  r.dispatch(InputChanged(a.to_int()), 7)
  r.dispatch(InputChanged(b.to_int()), 3)
  assert_eq(log, [107, 203])
}

///|
test "input submit handlers dispatch by input_id only" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.new_input_id()
  r.on_submit(a, fn(view) { log.push(view) })
  r.dispatch(InputSubmit(a.to_int()), 4)
  assert_eq(log, [4])
}

///|
test "unknown input id is a no-op for both input kinds" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.new_input_id()
  r.on_input_changed(a, fn(_) { log.push(1) })
  r.on_submit(a, fn(_) { log.push(2) })
  r.dispatch(InputChanged(999), 0)
  r.dispatch(InputSubmit(999), 0)
  assert_eq(log, [])
}

///|
test "re-registering an input id replaces the handler" {
  // Single-dispatch per id, like click: a second registration wins.
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.new_input_id()
  r.on_submit(a, fn(_) { log.push(1) })
  r.on_submit(a, fn(_) { log.push(2) })
  r.dispatch(InputSubmit(a.to_int()), 0)
  assert_eq(log, [2])
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
  let a = r.on_click(fn(_) {  }).to_int()
  let b = r.on_key(fn(_, _) {  })
  let c = r.on_named_key(fn(_, _) {  })
  let d = r.on_text(fn(_) {  })
  let e = r.new_input_id().to_int()
  assert_eq([a, b, c, d, e], [1, 2, 3, 4, 5])
}

///|
test "new_scroll_id issues distinct ids sharing the handler counter" {
  let r = HandlerRegistry::new()
  let click = r.on_click(fn(_) {  }).to_int()
  let a = r.new_scroll_id().to_int()
  let b = r.new_scroll_id().to_int()
  // Ids come off one shared counter: click took 1, the scroll ids take 2 and 3.
  assert_eq([click, a, b], [1, 2, 3])
  if a == b {
    fail("scroll ids must be distinct")
  }
}

///|
test "scroll handlers dispatch by scroll_id only" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.new_scroll_id()
  let b = r.new_scroll_id()
  r.on_scroll(a, fn(view) { log.push(100 + view) })
  r.on_scroll(b, fn(view) { log.push(200 + view) })
  r.dispatch(Scroll(a.to_int()), 7)
  r.dispatch(Scroll(b.to_int()), 3)
  assert_eq(log, [107, 203])
}

///|
test "unknown scroll id is a no-op" {
  let r = HandlerRegistry::new()
  let log : Array[Int] = []
  let a = r.new_scroll_id()
  r.on_scroll(a, fn(_) { log.push(1) })
  r.dispatch(Scroll(999), 0)
  assert_eq(log, [])
}
