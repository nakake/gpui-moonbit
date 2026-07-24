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

///|
test "command buffer set_padding wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_padding(4.0)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_PADDING | f32 padding (LE).
  assert_eq(b[8].to_int(), OP_SET_PADDING)
  // 4.0f32 = 0x40800000 -> little-endian 00 00 80 40.
  assert_eq(b[9], b'\x00')
  assert_eq(b[10], b'\x00')
  assert_eq(b[11], b'\x80')
  assert_eq(b[12], b'\x40')
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_border wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_border(2.0, 10, 20, 30)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_BORDER | f32 width | r u8 | g u8 | b u8.
  assert_eq(b[8].to_int(), OP_SET_BORDER)
  // 2.0f32 = 0x40000000 -> little-endian 00 00 00 40.
  assert_eq(b[9], b'\x00')
  assert_eq(b[10], b'\x00')
  assert_eq(b[11], b'\x00')
  assert_eq(b[12], b'\x40')
  assert_eq(b[13], b'\x0A')
  assert_eq(b[14], b'\x14')
  assert_eq(b[15], b'\x1E')
  assert_eq(b.length(), 16)
}

// --- G23: MoonBit native Int is a 32-bit two's-complement machine word ------
//
// The whole Rust↔MoonBit bridge assumes `Int` == `i32` across the C boundary.
// These assertions hold ONLY for a 32-bit wrapping Int: on a 64-bit Int,
// `0x7FFFFFFF + 1` would stay positive (2147483648) and the test would fail.
// The cross-boundary half of this check lives in cmd/roundtrip (gpui_abi_probe).

///|
test "Int wraps at the i32 boundary (32-bit machine word)" {
  // 0x7FFFFFFF is i32::MAX; +1 must wrap to i32::MIN (negative).
  assert_eq(0x7FFFFFFF + 1, -0x80000000)
  assert_true(0x7FFFFFFF + 1 < 0)
  // -0x80000000 is i32::MIN; -1 must wrap to i32::MAX (positive).
  assert_eq(-0x80000000 - 1, 0x7FFFFFFF)
  assert_true(-0x80000000 - 1 > 0)
}

// --- G20: structured error classification ----------------------------------

///|
test "classify_status maps every GPUI_STATUS_* code" {
  assert_eq(classify_status(-1).code(), -1)
  assert_eq(classify_status(-9).code(), -9)
  match classify_status(-1) {
    InvalidHandle => ()
    _ => fail("expected InvalidHandle")
  }
  match classify_status(-9) {
    DuplicateKey => ()
    _ => fail("expected DuplicateKey")
  }
  // Unmapped codes (including success 0) fall through to Unknown, kept verbatim.
  match classify_status(0) {
    Unknown(0) => ()
    _ => fail("expected Unknown(0)")
  }
  match classify_status(-99) {
    Unknown(-99) => ()
    _ => fail("expected Unknown(-99)")
  }
}

///|
test "status_message is a non-empty one-liner per code" {
  let codes = [-1, -2, -3, -4, -5, -6, -7, -8, -9, 0, -99]
  for c in codes {
    let msg = status_message(c)
    assert_true(msg.length() > 0)
    // One line: no embedded newline.
    assert_true(!msg.contains("\n"))
  }
}

///|
test "GpuiError to_string carries code and message" {
  let err = classify_status(-8)
  let s = err.to_string()
  assert_true(s.contains("-8"))
  assert_true(s.contains("GpuiError"))
  assert_eq(err.message(), status_message(-8))
}
