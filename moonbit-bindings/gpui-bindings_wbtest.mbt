// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

test "to_cstring_bytes: ascii is full utf8 with trailing NUL" {
  let b = to_cstring_bytes("GPUI + MoonBit")
  // 14 code units + 1 NUL terminator (the old String FFI truncated to 1 char).
  assert_eq(b.length(), 15)
  assert_eq(b[0], b'G')
  assert_eq(b[13], b't')
  assert_eq(b[14], b'\x00')
  // No interior NUL before the terminator (would truncate a C string early).
  for i in 0..<14 {
    assert_not_eq(b[i], b'\x00')
  }
}

test "to_cstring_bytes: multibyte is UTF-8 encoded" {
  // "あ" is U+3042 -> UTF-8 0xE3 0x81 0x82, then NUL.
  let b = to_cstring_bytes("あ")
  assert_eq(b.length(), 4)
  assert_eq(b[0], b'\xE3')
  assert_eq(b[1], b'\x81')
  assert_eq(b[2], b'\x82')
  assert_eq(b[3], b'\x00')
}

test "to_cstring_bytes: empty string is a single NUL" {
  let b = to_cstring_bytes("")
  assert_eq(b.length(), 1)
  assert_eq(b[0], b'\x00')
}
