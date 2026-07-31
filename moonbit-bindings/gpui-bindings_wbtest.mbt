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

///|
fn read_i32_le(b : Bytes, offset : Int) -> Int {
  // MoonBit's Int is a 32-bit wrapping two's-complement word, so the four
  // little-endian bytes assembled by read_u32_le already carry the correct
  // signed i32 value (see the "Int wraps at the i32 boundary" test below).
  read_u32_le(b, offset)
}

///|
test "command buffer set_bg_color wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_bg_color(Color::rgba(10, 20, 30, 128))
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_BG_COLOR | r u8 | g u8 | b u8 | a u8.
  assert_eq(b[8].to_int(), OP_SET_BG_COLOR)
  assert_eq(b[9], b'\x0A')
  assert_eq(b[10], b'\x14')
  assert_eq(b[11], b'\x1E')
  assert_eq(b[12], b'\x80')
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_margin wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_margin(1, 2, 3, 4)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_MARGIN | top i32 | right i32 | bottom i32 | left i32.
  assert_eq(b[8].to_int(), OP_SET_MARGIN)
  assert_eq(read_i32_le(b, 9), 1)
  assert_eq(read_i32_le(b, 13), 2)
  assert_eq(read_i32_le(b, 17), 3)
  assert_eq(read_i32_le(b, 21), 4)
  assert_eq(b.length(), 25)
}

///|
test "command buffer set_flex wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_flex(1.5, 0.5, 100.0)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_FLEX_ITEM | grow_x1000 i32 | shrink_x1000 i32 | basis_px i32.
  assert_eq(b[8].to_int(), OP_SET_FLEX_ITEM)
  assert_eq(read_i32_le(b, 9), 1500) // 1.5 * 1000
  assert_eq(read_i32_le(b, 13), 500) // 0.5 * 1000
  assert_eq(read_i32_le(b, 17), 100) // basis px
  assert_eq(b.length(), 21)
}

///|
test "command buffer set_opacity wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_opacity(0.5)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_OPACITY | x1000 i32.
  assert_eq(b[8].to_int(), OP_SET_OPACITY)
  assert_eq(read_i32_le(b, 9), 500) // 0.5 * 1000
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_shadow wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_shadow(0, 4, 6, -1, Color::rgba(0, 0, 0, 64))
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_SHADOW | x i32 | y i32 | blur i32 | spread i32 | r u8 | g u8 | b u8 | a u8.
  assert_eq(b[8].to_int(), OP_SET_SHADOW)
  assert_eq(read_i32_le(b, 9), 0)
  assert_eq(read_i32_le(b, 13), 4)
  assert_eq(read_i32_le(b, 17), 6)
  assert_eq(read_i32_le(b, 21), -1)
  assert_eq(b[25], b'\x00')
  assert_eq(b[26], b'\x00')
  assert_eq(b[27], b'\x00')
  assert_eq(b[28], b'\x40')
  assert_eq(b.length(), 29)
}

///|
test "command buffer set_align wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_align(ALIGN_CENTER, JUSTIFY_SPACE_BETWEEN)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_ALIGN | align_items i32 | justify_content i32.
  assert_eq(b[8].to_int(), OP_SET_ALIGN)
  assert_eq(read_i32_le(b, 9), ALIGN_CENTER)
  assert_eq(read_i32_le(b, 13), JUSTIFY_SPACE_BETWEEN)
  assert_eq(b.length(), 17)
}

///|
test "command buffer set_overflow wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_overflow(OVERFLOW_HIDDEN, OVERFLOW_SCROLL)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_OVERFLOW | x_mode i32 | y_mode i32.
  assert_eq(b[8].to_int(), OP_SET_OVERFLOW)
  assert_eq(read_i32_le(b, 9), OVERFLOW_HIDDEN)
  assert_eq(read_i32_le(b, 13), OVERFLOW_SCROLL)
  assert_eq(b.length(), 17)
}

///|
test "command buffer set_cursor wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_cursor(CURSOR_POINTER)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_CURSOR | kind i32.
  assert_eq(b[8].to_int(), OP_SET_CURSOR)
  assert_eq(read_i32_le(b, 9), CURSOR_POINTER)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_absolute wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_absolute(POSITION_ABSOLUTE)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_POSITION | mode i32.
  assert_eq(b[8].to_int(), OP_SET_POSITION)
  assert_eq(read_i32_le(b, 9), POSITION_ABSOLUTE)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_inset wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_inset(10, -1, 20, -1)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_INSET | top i32 | right i32 | bottom i32 | left i32.
  assert_eq(b[8].to_int(), OP_SET_INSET)
  assert_eq(read_i32_le(b, 9), 10)
  assert_eq(read_i32_le(b, 13), -1)
  assert_eq(read_i32_le(b, 17), 20)
  assert_eq(read_i32_le(b, 21), -1)
  assert_eq(b.length(), 25)
}

///|
test "command buffer set_min_size wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_min_size(100, -1)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_MIN_SIZE | w i32 | h i32.
  assert_eq(b[8].to_int(), OP_SET_MIN_SIZE)
  assert_eq(read_i32_le(b, 9), 100)
  assert_eq(read_i32_le(b, 13), -1)
  assert_eq(b.length(), 17)
}

///|
test "command buffer set_max_size wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_max_size(-1, 400)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_MAX_SIZE | w i32 | h i32.
  assert_eq(b[8].to_int(), OP_SET_MAX_SIZE)
  assert_eq(read_i32_le(b, 9), -1)
  assert_eq(read_i32_le(b, 13), 400)
  assert_eq(b.length(), 17)
}

///|
test "command buffer set_padding_sides wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_padding_sides(5, 6, 7, 8)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_PADDING_SIDES | top i32 | right i32 | bottom i32 | left i32.
  assert_eq(b[8].to_int(), OP_SET_PADDING_SIDES)
  assert_eq(read_i32_le(b, 9), 5)
  assert_eq(read_i32_le(b, 13), 6)
  assert_eq(read_i32_le(b, 17), 7)
  assert_eq(read_i32_le(b, 21), 8)
  assert_eq(b.length(), 25)
}

// --- G8 typography wire format (issue #51) ---------------------------------

///|
test "command buffer set_text_size wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_text_size(18)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_TEXT_SIZE | size i32.
  assert_eq(b[8].to_int(), OP_SET_TEXT_SIZE)
  assert_eq(read_i32_le(b, 9), 18)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_text_color wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_text_color(Color::rgba(10, 20, 30, 128))
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_TEXT_COLOR | r u8 | g u8 | b u8 | a u8.
  assert_eq(b[8].to_int(), OP_SET_TEXT_COLOR)
  assert_eq(b[9], b'\x0A')
  assert_eq(b[10], b'\x14')
  assert_eq(b[11], b'\x1E')
  assert_eq(b[12], b'\x80')
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_font_weight wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_font_weight(700)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_FONT_WEIGHT | weight i32.
  assert_eq(b[8].to_int(), OP_SET_FONT_WEIGHT)
  assert_eq(read_i32_le(b, 9), 700)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_line_height wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_line_height(1.5)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_LINE_HEIGHT | px_x1000 i32.
  assert_eq(b[8].to_int(), OP_SET_LINE_HEIGHT)
  assert_eq(read_i32_le(b, 9), 1500) // 1.5 * 1000
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_text_align wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_text_align(TEXT_ALIGN_CENTER)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_TEXT_ALIGN | id i32.
  assert_eq(b[8].to_int(), OP_SET_TEXT_ALIGN)
  assert_eq(read_i32_le(b, 9), TEXT_ALIGN_CENTER)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_whitespace wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_whitespace(WHITESPACE_NOWRAP)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_WHITESPACE | id i32.
  assert_eq(b[8].to_int(), OP_SET_WHITESPACE)
  assert_eq(read_i32_le(b, 9), WHITESPACE_NOWRAP)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_font_family wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_font_family("あ")
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_FONT_FAMILY | u32 length | UTF-8 payload.
  assert_eq(b[8].to_int(), OP_SET_FONT_FAMILY)
  assert_eq(read_u32_le(b, 9), 3) // "あ" = E3 81 82
  assert_eq(b[13], b'\xE3')
  assert_eq(b[14], b'\x81')
  assert_eq(b[15], b'\x82')
  assert_eq(b.length(), 16)
}

// --- Keyboard navigation / a11y wire format (issue #52) --------------------

///|
test "command buffer set_focusable wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_focusable(1)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_FOCUSABLE | mode i32.
  assert_eq(b[8].to_int(), OP_SET_FOCUSABLE)
  assert_eq(read_i32_le(b, 9), 1)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_tab_index wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_tab_index(3)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_TAB_INDEX | index i32.
  assert_eq(b[8].to_int(), OP_SET_TAB_INDEX)
  assert_eq(read_i32_le(b, 9), 3)
  assert_eq(b.length(), 13)
}

///|
test "command buffer set_tab_stop wire format matches the Rust decoder layout" {
  let cb = CommandBuffer::new()
  cb.set_tab_stop(0)
  let b = cb.to_bytes()
  // 8-byte header, then OP_SET_TAB_STOP | mode i32.
  assert_eq(b[8].to_int(), OP_SET_TAB_STOP)
  assert_eq(read_i32_le(b, 9), 0)
  assert_eq(b.length(), 13)
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
  assert_eq(classify_status(-10).code(), -10)
  assert_eq(classify_status(-11).code(), -11)
  assert_eq(classify_status(-12).code(), -12)
  match classify_status(-1) {
    InvalidHandle => ()
    _ => fail("expected InvalidHandle")
  }
  match classify_status(-9) {
    DuplicateKey => ()
    _ => fail("expected DuplicateKey")
  }
  match classify_status(-10) {
    KeyNotFound => ()
    _ => fail("expected KeyNotFound")
  }
  match classify_status(-11) {
    QueueFull => ()
    _ => fail("expected QueueFull")
  }
  match classify_status(-12) {
    PayloadTooLarge => ()
    _ => fail("expected PayloadTooLarge")
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
  let codes = [-1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, 0, -99]
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
