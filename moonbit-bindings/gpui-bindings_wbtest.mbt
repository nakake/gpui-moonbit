// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "clamp_color_component: clamps to the byte range" {
  assert_eq(clamp_color_component(-1), 0)
  assert_eq(clamp_color_component(0), 0)
  assert_eq(clamp_color_component(128), 128)
  assert_eq(clamp_color_component(255), 255)
  assert_eq(clamp_color_component(300), 255)
}

///|
test "to_utf8_bytes: ascii is full utf8 without a terminator" {
  let b = to_utf8_bytes("GPUI + MoonBit")
  assert_eq(b.length(), 14)
  assert_eq(b[0], b'G')
  assert_eq(b[13], b't')
  for i in 0..<14 {
    assert_not_eq(b[i], b'\x00')
  }
}

///|
test "to_utf8_bytes: multibyte is UTF-8 encoded" {
  // "あ" is U+3042 -> UTF-8 0xE3 0x81 0x82.
  let b = to_utf8_bytes("あ")
  assert_eq(b.length(), 3)
  assert_eq(b[0], b'\xE3')
  assert_eq(b[1], b'\x81')
  assert_eq(b[2], b'\x82')
}

///|
test "to_utf8_bytes: empty string is empty" {
  let b = to_utf8_bytes("")
  assert_eq(b.length(), 0)
}

///|
fn read_u32_le(b : Bytes, offset : Int) -> Int {
  b[offset].to_int() +
  b[offset + 1].to_int() * 256 +
  b[offset + 2].to_int() * 65536 +
  b[offset + 3].to_int() * 16777216
}

///|
test "to_utf8_bytes: embedded NUL is data, not a terminator" {
  let b = to_utf8_bytes("A\u{0}B")
  assert_eq(b.length(), 3)
  assert_eq(b[0], b'A')
  assert_eq(b[1], b'\x00')
  assert_eq(b[2], b'B')
}

///|
test "command buffer wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.text("あ", 4, 5, 6, 14.0)
  cb.set_root()
  let b = cb.to_bytes()
  // Header: magic "GPUI" + BUFFER_VERSION (u32 LE).
  assert_eq(b[0], b'G')
  assert_eq(b[1], b'P')
  assert_eq(b[2], b'U')
  assert_eq(b[3], b'I')
  assert_eq(read_u32_le(b, 4), BUFFER_VERSION)
  // OP_TEXT: opcode, u32 length, UTF-8 payload, RGB, f32 size (LE).
  assert_eq(b[8].to_int(), OP_TEXT)
  assert_eq(read_u32_le(b, 9), 3) // "あ" = E3 81 82
  assert_eq(b[13], b'\xE3')
  assert_eq(b[14], b'\x81')
  assert_eq(b[15], b'\x82')
  assert_eq(b[16], b'\x04')
  assert_eq(b[17], b'\x05')
  assert_eq(b[18], b'\x06')
  // 14.0f32 = 0x41600000 -> little-endian 00 00 60 41.
  assert_eq(b[19], b'\x00')
  assert_eq(b[20], b'\x00')
  assert_eq(b[21], b'\x60')
  assert_eq(b[22], b'\x41')
  assert_eq(b[23].to_int(), OP_SET_ROOT)
  assert_eq(b.length(), 24)
}

///|
test "command buffer text carries embedded NUL as payload data" {
  let cb = CommandBuffer::new()
  cb.text("A\u{0}B", 0, 0, 0, 1.0)
  cb.set_root()
  let b = cb.to_bytes()
  assert_eq(b[8].to_int(), OP_TEXT)
  assert_eq(read_u32_le(b, 9), 3)
  assert_eq(b[13], b'A')
  assert_eq(b[14], b'\x00')
  assert_eq(b[15], b'B')
}
