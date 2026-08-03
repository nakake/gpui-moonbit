// Blackbox tests run against the package's public API. Use `@gpui-bindings` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
fn read_u32_le(b : Bytes, offset : Int) -> Int {
  b[offset].to_int() +
  b[offset + 1].to_int() * 256 +
  b[offset + 2].to_int() * 65536 +
  b[offset + 3].to_int() * 16777216
}

///|
// True when `opcode` appears anywhere followed by `operand` as u32 LE. Scanning
// for the opcode byte alone would pass on an unrelated float or length prefix
// that happens to hold the same value, so the operand is matched with it.
fn has_op_with_u32(b : Bytes, opcode : Int, operand : Int) -> Bool {
  for j in 0..<(b.length() - 4) {
    if b[j].to_int() == opcode && read_u32_le(b, j + 1) == operand {
      return true
    }
  }
  false
}

///|
fn all_distinct(vals : Array[Int]) -> Bool {
  for i in 0..<vals.length() {
    for j in (i + 1)..<vals.length() {
      if vals[i] == vals[j] {
        return false
      }
    }
  }
  true
}

///|
fn is_power_of_two(x : Int) -> Bool {
  x > 0 && (x & (x - 1)) == 0
}

///|
fn channels(c : @gpui-bindings.Color) -> Array[Int] {
  [c.red, c.green, c.blue, c.alpha]
}

///|
test "build a whole tree with public API only" {
  let cb = @gpui-bindings.CommandBuffer::new()
  cb.div()
  cb.set_bg_color(@gpui-bindings.Color::rgb(10, 20, 30))
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(8.0)
  cb.set_padding(4.0)
  cb.text("hello", 255, 255, 255, 14.0)
  cb.add_child()
  cb.set_root()
  let b = cb.to_bytes()
  // Header: magic "GPUI" + BUFFER_VERSION (u32 LE).
  assert_eq(b[0], b'G')
  assert_eq(b[1], b'P')
  assert_eq(b[2], b'U')
  assert_eq(b[3], b'I')
  assert_eq(read_u32_le(b, 4), @gpui-bindings.BUFFER_VERSION)
  // First opcode right after the 8-byte header is the div.
  assert_eq(b[8].to_int(), @gpui-bindings.OP_DIV)
  // The tree is committed, so the trailing opcode is OP_SET_ROOT.
  assert_eq(b[b.length() - 1].to_int(), @gpui-bindings.OP_SET_ROOT)
}

///|
test "color constructors fill all four channels" {
  // Read the fields directly: a consumer that cannot see them cannot inspect a
  // Color it was handed, so the field access is itself part of the contract.
  assert_eq(channels(@gpui-bindings.Color::rgb(1, 2, 3)), [1, 2, 3, 255])
  assert_eq(channels(@gpui-bindings.Color::rgba(5, 6, 7, 200)), [5, 6, 7, 200])
  assert_eq(channels(@gpui-bindings.Color::black()), [0, 0, 0, 255])
  assert_eq(channels(@gpui-bindings.Color::white()), [255, 255, 255, 255])
  assert_eq(channels(@gpui-bindings.Color::transparent()), [0, 0, 0, 0])
}

///|
test "classify_status round-trips every known negative code" {
  let known = [-1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15]
  for c in known {
    assert_eq(@gpui-bindings.classify_status(c).code(), c)
  }
}

///|
test "classify_status keeps out-of-range and zero as Unknown" {
  assert_eq(@gpui-bindings.classify_status(0).code(), 0)
  assert_eq(@gpui-bindings.classify_status(-99).code(), -99)
}

///|
test "status_message is a non-empty one-liner for every code" {
  let codes = [
    -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15, 0, -99,
  ]
  for c in codes {
    let msg = @gpui-bindings.status_message(c)
    assert_true(msg.length() > 0)
    assert_true(!msg.contains("\n"))
  }
}

///|
test "GpuiError::message matches status_message" {
  assert_eq(
    @gpui-bindings.classify_status(-8).message(),
    @gpui-bindings.status_message(-8),
  )
  assert_eq(
    @gpui-bindings.classify_status(-13).message(),
    @gpui-bindings.status_message(-13),
  )
}

///|
test "GpuiError::to_string carries both the code and the message" {
  let expected_known = "GpuiError(-8): \{@gpui-bindings.status_message(-8)}"
  assert_eq(@gpui-bindings.classify_status(-8).to_string(), expected_known)
  let expected_unknown = "GpuiError(-99): unknown status code -99"
  assert_eq(@gpui-bindings.classify_status(-99).to_string(), expected_unknown)
}

///|
test "expect_ok returns through on Ok" {
  @gpui-bindings.expect_ok(Ok(()), "no-op context")
}

///|
test "panic expect_ok aborts on Err" {
  @gpui-bindings.expect_ok(Err(-5), "boom")
}

///|
test "store cells are readable and writable externally" {
  let store = @gpui-bindings.Store::new()
  let count = store.new_cell(10)
  let name = store.new_cell("hi")
  assert_eq(store.get(count), 10)
  assert_eq(store.get(name), "hi")
  store.set(count, 32)
  store.set(name, "yo")
  assert_eq(store.get(count), 32)
  assert_eq(store.get(name), "yo")
}

///|
test "store dirty tracking is observable from outside" {
  let store = @gpui-bindings.Store::new()
  let cell = store.new_cell(3)
  store.begin_dirty_tracking()
  assert_eq(store.has_dirty(), false)
  ignore(store.get(cell))
  assert_eq(store.has_dirty(), false)
  store.set(cell, 5)
  assert_eq(store.has_dirty(), true)
}

///|
test "signal tracks the store cell and sets dirt" {
  let store = @gpui-bindings.Store::new()
  let cell = store.new_cell(0)
  let sig = store.signal(cell)
  store.begin_dirty_tracking()
  assert_eq(sig.get(store), 0)
  sig.set(store, 5)
  assert_eq(sig.get(store), 5)
  assert_eq(store.has_dirty(), true)
}

///|
test "HandlerRegistry dispatches clicks issued through on_click" {
  let r = @gpui-bindings.HandlerRegistry::new()
  let log : Array[Int] = []
  let id = r.on_click(fn(view) { log.push(100 + view) })
  r.dispatch(@gpui-bindings.Event::Click(id.to_int()), 7)
  assert_eq(log, [107])
  r.dispatch(@gpui-bindings.Event::Click(999999), 3)
  assert_eq(log, [107])
}

///|
test "HandlerRegistry dispatches text input submit" {
  let r = @gpui-bindings.HandlerRegistry::new()
  let log : Array[Int] = []
  let input_id = r.new_input_id()
  r.on_submit(input_id, fn(view) { log.push(view) })
  r.dispatch(@gpui-bindings.Event::InputSubmit(input_id.to_int()), 4)
  assert_eq(log, [4])
}

///|
test "button component emits a subtree through the public API" {
  let cb = @gpui-bindings.CommandBuffer::new()
  let store = @gpui-bindings.Store::new()
  let handlers = @gpui-bindings.HandlerRegistry::new()
  // A consumer assembles the render context from the outside and reads it back.
  let ctx : @gpui-bindings.RenderCtx = { view: 0, store, handlers }
  assert_eq(ctx.view, 0)
  // Burn a few ids first: the id under test must not be the registry's first
  // one, or a component that wrote a raw `1` would satisfy the check below.
  for _ in 0..<4 {
    ignore(ctx.handlers.on_click(fn(_) {  }))
  }
  let id = ctx.handlers.on_click(fn(_) {  })
  assert_not_eq(id.to_int(), 1)
  @gpui-bindings.button(cb, {
    key: "b1",
    label: "OK",
    color: @gpui-bindings.Color::rgb(10, 20, 30),
    on_click: id,
  })
  let b = cb.to_bytes()
  assert_true(b.length() > 8)
  // The registry-issued id must reach the wire, not just the opcode.
  assert_true(has_op_with_u32(b, @gpui-bindings.OP_SET_ON_CLICK, id.to_int()))
}

///|
test "checkbox and labeled_row grow the buffer" {
  let cb = @gpui-bindings.CommandBuffer::new()
  @gpui-bindings.checkbox(cb, true, "Enable", 42)
  assert_true(cb.to_bytes().length() > 8)
  let row = @gpui-bindings.CommandBuffer::new()
  @gpui-bindings.labeled_row(row, "k", "Name", "value")
  assert_true(row.to_bytes().length() > 8)
}

///|
test "ABI constants are public and distinct" {
  assert_true(@gpui-bindings.ABI_VERSION > 0)
  let events = [
    @gpui-bindings.EVENT_CLICK,
    @gpui-bindings.EVENT_KEY,
    @gpui-bindings.EVENT_TEXT,
    @gpui-bindings.EVENT_NAMED_KEY,
    @gpui-bindings.EVENT_ASYNC,
    @gpui-bindings.EVENT_INPUT_CHANGED,
    @gpui-bindings.EVENT_INPUT_SUBMIT,
  ]
  assert_true(all_distinct(events))
  let mods = [
    @gpui-bindings.MOD_CTRL,
    @gpui-bindings.MOD_ALT,
    @gpui-bindings.MOD_SHIFT,
    @gpui-bindings.MOD_PLATFORM,
    @gpui-bindings.MOD_FUNCTION,
  ]
  assert_true(all_distinct(mods))
  for m in mods {
    assert_true(is_power_of_two(m))
  }
}

///|
test "scroll feedback public API: issue id, subscribe, dispatch, encode" {
  let r = @gpui-bindings.HandlerRegistry::new()
  let sid = r.new_scroll_id()
  let log : Array[Int] = []
  r.on_scroll(sid, fn(view) { log.push(view) })
  r.dispatch(@gpui-bindings.Scroll(sid.to_int()), 5)
  assert_eq(log, [5])
  let cb = @gpui-bindings.CommandBuffer::new()
  cb.div()
  cb.set_key("list")
  cb.set_overflow(
    @gpui-bindings.OVERFLOW_VISIBLE,
    @gpui-bindings.OVERFLOW_SCROLL,
  )
  cb.set_scroll_id(sid.to_int())
  cb.set_root()
  assert_true(
    has_op_with_u32(
      cb.to_bytes(),
      @gpui-bindings.OP_SET_SCROLL_ID,
      sid.to_int(),
    ),
  )
}

///|
test "ScrollState fields are publicly constructible and readable" {
  let st : @gpui-bindings.ScrollState = {
    offset_x: 0.0,
    offset_y: -30.0,
    max_x: 0.0,
    max_y: 400.0,
    viewport_w: 200.0,
    viewport_h: 100.0,
  }
  assert_eq(st.offset_y, -30.0)
  assert_eq(st.max_y, 400.0)
  assert_eq(st.viewport_w, 200.0)
}

///|
test "rich text public API emits runs with UTF-8 byte offsets" {
  let cb = @gpui-bindings.CommandBuffer::new()
  cb.div()
  cb.rich_text(
    [
      ("あ", None),
      ("いう", Some(@gpui-bindings.RunStyle::new(weight=700))),
      ("x", None),
    ],
    255,
    255,
    255,
    14.0,
  )
  cb.add_child()
  cb.set_root()
  let b = cb.to_bytes()
  // The styled segment starts at UTF-8 byte 3 ("あ" is 3 bytes): the run
  // record's start operand directly follows the opcode byte.
  assert_true(has_op_with_u32(b, @gpui-bindings.OP_TEXT_RUN, 3))
}

///|
test "text_run public API applies to the pushed text node" {
  let cb = @gpui-bindings.CommandBuffer::new()
  cb.text("ab", 255, 255, 255, 14.0)
  cb.text_run(
    1,
    1,
    @gpui-bindings.RunStyle::new(
      color=@gpui-bindings.Color::rgba(1, 2, 3, 4),
      italic=true,
      underline=true,
      strikethrough=true,
      background=@gpui-bindings.Color::rgb(9, 9, 9),
    ),
  )
  cb.set_root()
  assert_true(has_op_with_u32(cb.to_bytes(), @gpui-bindings.OP_TEXT_RUN, 1))
}
