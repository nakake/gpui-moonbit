// Whitebox tests for the reusable components (RFC 0001 §3.1). Pin the exact
// wire output of `button` so a regression (wrong opcode, swapped operand,
// dropped child) fails here rather than at runtime. The `Cursor` byte reader
// is shared with widgets_wbtest.mbt (same package).

///|
test "button emits a keyed clickable div with a label child" {
  let cb = CommandBuffer::new()
  button(cb, {
    key: "b1",
    label: "OK",
    color: Color::rgb(10, 20, 30),
    on_click: { raw: 5 },
  })
  let b = cb.to_bytes()
  let c = { b, pos: 8 } // skip the 8-byte header
  // outer clickable div
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_KEY)
  assert_eq(c.u32(), 2) // "b1"
  assert_eq(c.u8(), 0x62) // 'b'
  assert_eq(c.u8(), 0x31) // '1'
  assert_eq(c.u8(), OP_SET_SIZE)
  assert_eq(c.f32_bits(), 0x42B80000) // 92.0
  assert_eq(c.f32_bits(), 0x42600000) // 56.0
  assert_eq(c.u8(), OP_SET_BG_COLOR)
  assert_eq(c.u8(), 10)
  assert_eq(c.u8(), 20)
  assert_eq(c.u8(), 30)
  assert_eq(c.u8(), 255) // opaque
  assert_eq(c.u8(), OP_SET_ROUNDED)
  assert_eq(c.f32_bits(), 0x41200000) // 10.0
  assert_eq(c.u8(), OP_SET_FLEX)
  assert_eq(c.u8(), 1) // column
  assert_eq(c.u8(), OP_SET_CENTER)
  assert_eq(c.u8(), OP_SET_ON_CLICK)
  assert_eq(c.i32(), 5) // HandlerId raw value
  // label text "OK", white, size 18.0
  assert_eq(c.u8(), OP_TEXT)
  assert_eq(c.u32(), 2)
  assert_eq(c.u8(), 0x4F) // 'O'
  assert_eq(c.u8(), 0x4B) // 'K'
  assert_eq(c.u8(), 255)
  assert_eq(c.u8(), 255)
  assert_eq(c.u8(), 255)
  assert_eq(c.f32_bits(), 0x41900000) // 18.0
  assert_eq(c.u8(), OP_ADD_CHILD)
  // no trailing bytes: the component leaves the button div on the stack
  assert_eq(c.pos, b.length())
}

///|
test "button writes the handler id, not a raw constant" {
  // The id flows HandlerRegistry::on_click → ButtonProps.on_click → wire.
  let r = HandlerRegistry::new()
  let id = r.on_click(fn(_) {  })
  let cb = CommandBuffer::new()
  button(cb, { key: "k", label: "x", color: Color::black(), on_click: id })
  let b = cb.to_bytes()
  let c = { b, pos: 8 }
  // div, set_key ("k"), set_size (2×f32), set_bg_color (4 bytes), set_rounded
  // (f32), set_flex (1), set_center, set_on_click — then the i32 id.
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_KEY)
  assert_eq(c.u32(), 1)
  ignore(c.u8())
  assert_eq(c.u8(), OP_SET_SIZE)
  ignore(c.f32_bits())
  ignore(c.f32_bits())
  assert_eq(c.u8(), OP_SET_BG_COLOR)
  ignore(c.u8())
  ignore(c.u8())
  ignore(c.u8())
  ignore(c.u8())
  assert_eq(c.u8(), OP_SET_ROUNDED)
  ignore(c.f32_bits())
  assert_eq(c.u8(), OP_SET_FLEX)
  ignore(c.u8())
  assert_eq(c.u8(), OP_SET_CENTER)
  assert_eq(c.u8(), OP_SET_ON_CLICK)
  assert_eq(c.i32(), id.to_int())
}

///|
test "text_input emits a keyed frame div with an OP_TEXT_INPUT leaf" {
  let cb = CommandBuffer::new()
  text_input(cb, { key: "in1", input_id: { raw: 9 }, placeholder: "あ" })
  let b = cb.to_bytes()
  let c = { b, pos: 8 } // skip the 8-byte header
  // outer frame div
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_KEY)
  assert_eq(c.u32(), 3) // "in1"
  assert_eq(c.u8(), 0x69) // 'i'
  assert_eq(c.u8(), 0x6E) // 'n'
  assert_eq(c.u8(), 0x31) // '1'
  assert_eq(c.u8(), OP_SET_BORDER)
  assert_eq(c.f32_bits(), 0x3F800000) // 1.0
  assert_eq(c.u8(), 120)
  assert_eq(c.u8(), 120)
  assert_eq(c.u8(), 140)
  assert_eq(c.u8(), OP_SET_ROUNDED)
  assert_eq(c.f32_bits(), 0x40C00000) // 6.0
  assert_eq(c.u8(), OP_SET_PADDING)
  assert_eq(c.f32_bits(), 0x41000000) // 8.0
  // input leaf: OP_TEXT_INPUT | input_id i32 | u32 len | UTF-8 placeholder
  assert_eq(c.u8(), OP_TEXT_INPUT)
  assert_eq(c.i32(), 9) // InputId raw value
  assert_eq(c.u32(), 3) // "あ" = E3 81 82
  assert_eq(c.u8(), 0xE3)
  assert_eq(c.u8(), 0x81)
  assert_eq(c.u8(), 0x82)
  assert_eq(c.u8(), OP_ADD_CHILD)
  // no trailing bytes: the component leaves the frame div on the stack
  assert_eq(c.pos, b.length())
}

///|
test "text_input writes the issued input id, not a raw constant" {
  // The id flows HandlerRegistry::new_input_id → TextInputProps.input_id → wire.
  let r = HandlerRegistry::new()
  let id = r.new_input_id()
  let cb = CommandBuffer::new()
  text_input(cb, { key: "k", input_id: id, placeholder: "" })
  let b = cb.to_bytes()
  let c = { b, pos: 8 }
  // div, set_key ("k"), set_border (f32 + 3 bytes), set_rounded (f32),
  // set_padding (f32) — then the input leaf with the i32 id.
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_KEY)
  assert_eq(c.u32(), 1)
  ignore(c.u8())
  assert_eq(c.u8(), OP_SET_BORDER)
  ignore(c.f32_bits())
  ignore(c.u8())
  ignore(c.u8())
  ignore(c.u8())
  assert_eq(c.u8(), OP_SET_ROUNDED)
  ignore(c.f32_bits())
  assert_eq(c.u8(), OP_SET_PADDING)
  ignore(c.f32_bits())
  assert_eq(c.u8(), OP_TEXT_INPUT)
  assert_eq(c.i32(), id.to_int())
  assert_eq(c.u32(), 0) // empty placeholder
  assert_eq(c.u8(), OP_ADD_CHILD)
}
