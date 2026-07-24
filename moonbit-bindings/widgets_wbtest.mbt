// Whitebox tests for the composite widgets (issue #51, G6). Each helper in
// widgets.mbt must emit ONLY existing opcodes in the expected order — no new ABI
// surface. These pin the exact wire output so a regression in a helper (wrong
// opcode, swapped operand, dropped child) fails here rather than at runtime.

///|
struct Cursor {
  b : Bytes
  mut pos : Int
}

///|
fn Cursor::u8(self : Cursor) -> Int {
  let v = self.b[self.pos].to_int()
  self.pos = self.pos + 1
  v
}

///|
fn Cursor::u32(self : Cursor) -> Int {
  let v = read_u32_le(self.b, self.pos)
  self.pos = self.pos + 4
  v
}

///|
fn Cursor::i32(self : Cursor) -> Int {
  let v = read_i32_le(self.b, self.pos)
  self.pos = self.pos + 4
  v
}

///|
fn Cursor::f32_bits(self : Cursor) -> Int {
  self.u32()
}

///|
test "checkbox (unchecked) emits only existing opcodes in order" {
  let cb = CommandBuffer::new()
  checkbox(cb, false, "OK", 7)
  let b = cb.to_bytes()
  let c = { b, pos: 8 } // skip the 8-byte header
  // outer clickable row div
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_FLEX)
  assert_eq(c.u8(), 0) // row
  assert_eq(c.u8(), OP_SET_GAP)
  assert_eq(c.f32_bits(), 0x40C00000) // 6.0
  assert_eq(c.u8(), OP_SET_CENTER)
  assert_eq(c.u8(), OP_SET_ON_CLICK)
  assert_eq(c.i32(), 7)
  // glyph text "☐" (U+2610 = E2 98 90), rgb (200,200,210), size 18.0
  assert_eq(c.u8(), OP_TEXT)
  assert_eq(c.u32(), 3)
  assert_eq(c.u8(), 0xE2)
  assert_eq(c.u8(), 0x98)
  assert_eq(c.u8(), 0x90)
  assert_eq(c.u8(), 200)
  assert_eq(c.u8(), 200)
  assert_eq(c.u8(), 210)
  assert_eq(c.f32_bits(), 0x41900000) // 18.0
  assert_eq(c.u8(), OP_ADD_CHILD)
  // label text "OK", rgb (220,220,230), size 16.0
  assert_eq(c.u8(), OP_TEXT)
  assert_eq(c.u32(), 2)
  assert_eq(c.u8(), 0x4F) // 'O'
  assert_eq(c.u8(), 0x4B) // 'K'
  assert_eq(c.u8(), 220)
  assert_eq(c.u8(), 220)
  assert_eq(c.u8(), 230)
  assert_eq(c.f32_bits(), 0x41800000) // 16.0
  assert_eq(c.u8(), OP_ADD_CHILD)
  // no trailing bytes: the composite leaves the outer div on the stack
  assert_eq(c.pos, b.length())
}

///|
test "checkbox (checked) swaps only the glyph" {
  let cb = CommandBuffer::new()
  checkbox(cb, true, "OK", 7)
  let b = cb.to_bytes()
  let c = { b, pos: 8 }
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_FLEX)
  assert_eq(c.u8(), 0)
  assert_eq(c.u8(), OP_SET_GAP)
  ignore(c.f32_bits())
  assert_eq(c.u8(), OP_SET_CENTER)
  assert_eq(c.u8(), OP_SET_ON_CLICK)
  assert_eq(c.i32(), 7)
  // glyph text "☑" (U+2611 = E2 98 91) — the only difference from unchecked
  assert_eq(c.u8(), OP_TEXT)
  assert_eq(c.u32(), 3)
  assert_eq(c.u8(), 0xE2)
  assert_eq(c.u8(), 0x98)
  assert_eq(c.u8(), 0x91)
}

///|
test "labeled_row emits a keyed flex row with two text children" {
  let cb = CommandBuffer::new()
  labeled_row(cb, "row-1", "Name", "Ada")
  let b = cb.to_bytes()
  let c = { b, pos: 8 }
  // outer keyed row div
  assert_eq(c.u8(), OP_DIV)
  assert_eq(c.u8(), OP_SET_KEY)
  assert_eq(c.u32(), 5) // "row-1"
  assert_eq(c.u8(), 0x72) // 'r'
  assert_eq(c.u8(), 0x6F) // 'o'
  assert_eq(c.u8(), 0x77) // 'w'
  assert_eq(c.u8(), 0x2D) // '-'
  assert_eq(c.u8(), 0x31) // '1'
  assert_eq(c.u8(), OP_SET_FLEX)
  assert_eq(c.u8(), 0) // row
  assert_eq(c.u8(), OP_SET_GAP)
  assert_eq(c.f32_bits(), 0x41000000) // 8.0
  assert_eq(c.u8(), OP_SET_CENTER)
  // label text "Name", rgb (170,175,188), size 14.0
  assert_eq(c.u8(), OP_TEXT)
  assert_eq(c.u32(), 4)
  assert_eq(c.u8(), 0x4E) // 'N'
  assert_eq(c.u8(), 0x61) // 'a'
  assert_eq(c.u8(), 0x6D) // 'm'
  assert_eq(c.u8(), 0x65) // 'e'
  assert_eq(c.u8(), 170)
  assert_eq(c.u8(), 175)
  assert_eq(c.u8(), 188)
  assert_eq(c.f32_bits(), 0x41600000) // 14.0
  assert_eq(c.u8(), OP_ADD_CHILD)
  // value text "Ada", rgb (220,220,230), size 14.0
  assert_eq(c.u8(), OP_TEXT)
  assert_eq(c.u32(), 3)
  assert_eq(c.u8(), 0x41) // 'A'
  assert_eq(c.u8(), 0x64) // 'd'
  assert_eq(c.u8(), 0x61) // 'a'
  assert_eq(c.u8(), 220)
  assert_eq(c.u8(), 220)
  assert_eq(c.u8(), 230)
  assert_eq(c.f32_bits(), 0x41600000) // 14.0
  assert_eq(c.u8(), OP_ADD_CHILD)
  assert_eq(c.pos, b.length())
}
