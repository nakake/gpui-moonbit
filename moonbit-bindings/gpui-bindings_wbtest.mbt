// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

test "clamp_color_component: clamps to the byte range" {
  assert_eq(clamp_color_component(-1), 0)
  assert_eq(clamp_color_component(0), 0)
  assert_eq(clamp_color_component(128), 128)
  assert_eq(clamp_color_component(255), 255)
  assert_eq(clamp_color_component(300), 255)
}

test "to_utf8_bytes: ascii is full utf8 without a terminator" {
  let b = to_utf8_bytes("GPUI + MoonBit")
  assert_eq(b.length(), 14)
  assert_eq(b[0], b'G')
  assert_eq(b[13], b't')
  for i in 0..<14 {
    assert_not_eq(b[i], b'\x00')
  }
}

test "to_utf8_bytes: multibyte is UTF-8 encoded" {
  // "あ" is U+3042 -> UTF-8 0xE3 0x81 0x82.
  let b = to_utf8_bytes("あ")
  assert_eq(b.length(), 3)
  assert_eq(b[0], b'\xE3')
  assert_eq(b[1], b'\x81')
  assert_eq(b[2], b'\x82')
}

test "to_utf8_bytes: empty string is empty" {
  let b = to_utf8_bytes("")
  assert_eq(b.length(), 0)
}
