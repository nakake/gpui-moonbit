// Headless round-trip test (issue #34): MoonBit → C → Rust → C → MoonBit.
//
// Builds a tree with edge-case text (NUL byte, multibyte UTF-8, 4-byte emoji),
// submits via gpui_build_tree, reads back via gpui_debug_dump_text, and
// compares the dumped bytes against the expected encoding.
// Normal completion = pass (exit 0); abort = non-zero exit.

// Direct FFI declarations (not in root package → moon test unaffected).
#borrow(ptr)
extern "C" fn gpui_build_tree_ffi(view : Int, ptr : Bytes, len : Int) -> Int = "gpui_build_tree"

#borrow(buf)
extern "C" fn gpui_debug_dump_text_ffi(view : Int, buf : Bytes, len : Int) -> Int = "gpui_debug_dump_text"

// Cross-boundary ABI probe (issue #54, G23): echo i32 boundary values through
// Rust and back. MoonBit native `Int` must be ABI-compatible with Rust `i32`
// for the whole bridge; a width/sign mismatch corrupts silently, so we fail
// the build here instead.
extern "C" fn gpui_abi_probe_ffi(value : Int) -> Int = "gpui_abi_probe"

fn main {
  // Retain app.dispatch so the Rust staticlib's mb_dispatch reference resolves.
  let _keep : (Int, Int, Int, Int, Int) -> Int = @nakake/gpui-bindings/app.dispatch
  ignore(_keep)

  // Edge-case text: NUL byte, multibyte UTF-8 (hiragana), 4-byte emoji.
  let texts = ["A\u{0}あ", "🎉"]

  // Build tree: div { text(t0), text(t1) }
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div()
  for t in texts {
    cb.text(t, 255, 255, 255, 16.0)
    cb.add_child()
  }
  cb.set_root()

  // Submit via FFI
  let wire = cb.to_bytes()
  let status = gpui_build_tree_ffi(0, wire, wire.length())
  if status != 0 {
    abort("gpui_build_tree returned \{status}")
  }

  // Read back via FFI
  let cap = 1024
  let buf = Bytes::make(cap, b'\x00')
  let n = gpui_debug_dump_text_ffi(0, buf, cap)
  if n < 0 {
    abort("gpui_debug_dump_text returned \{n}")
  }

  // Build expected: len u32 LE + utf8 for each text, DFS pre-order
  let expected = @buffer.Buffer()
  for t in texts {
    let utf8 = @utf8.encode(t)
    expected.write_uint_le(utf8.length().reinterpret_as_uint())
    expected.write_bytes(utf8.view())
  }
  let expected_bytes = expected.to_bytes()

  // Compare
  if n != expected_bytes.length() {
    abort("length mismatch: got \{n}, want \{expected_bytes.length()}")
  }
  let got : BytesView = buf[0:n]
  let want : BytesView = expected_bytes.view()
  let mut i = 0
  while i < n {
    if got[i] != want[i] {
      abort("byte mismatch at offset \{i}")
    }
    i = i + 1
  }

  // Cross-boundary ABI probe (issue #54, G23): i32 boundary values must echo
  // back unchanged. 0x7FFFFFFF = i32::MAX, -0x80000000 = i32::MIN.
  let probe_values = [0x7FFFFFFF, -0x80000000, 0, -1, 42]
  for v in probe_values {
    let echoed = gpui_abi_probe_ffi(v)
    if echoed != v {
      abort("abi probe mismatch: sent \{v}, got \{echoed}")
    }
  }
  println("PASS: abi probe verified (\{probe_values.length()} values)")

  println("PASS: round-trip verified (\{n} bytes)")
}
