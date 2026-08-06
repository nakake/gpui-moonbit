// Stream example: the consumer side of async event injection (RFC 0002, #84).
//
// An external native producer (any thread, e.g. a Rust task or a C library)
// pushes opaque payloads with `gpui_post_event`; the main thread drains the
// queue and dispatches each one as `EVENT_ASYNC` through this package's
// `dispatch`. This example treats each payload as a UTF-8 text chunk, appends
// it to a running log, and updates the on-screen text in place.
//
// MoonBit has no thread primitive in this project's dependencies, so the
// producer is deliberately external: `post_event` is the FFI that native code
// calls, and `launch` shows how a MoonBit caller would inject from the main
// thread (e.g. a timer callback). The framing contract — "payloads are UTF-8
// chunks appended to the log" — lives entirely in this file; the library never
// interprets the bytes.
//
// This is a separate module that path-depends on the library (see moon.mod.json),
// so it exercises the exact route a third-party consumer takes: resolve the
// dependency, import `nakake/gpui-bindings/link` so the prebuild's link flags
// apply, register a dispatch, and run.

///|
let log : @buffer.Buffer = Buffer()

// Stable key for the log card's text node, addressed by `update_text` for the
// incremental in-place update (issue #10) so each injected chunk re-renders
// without a full tree rebuild.

///|
const LOG_KEY : String = "stream-log"

///|
priv enum Event {
  Async(Bytes) // injected payload (RFC 0002): a UTF-8 chunk to append
  Unknown
}

///|
fn decode(version : Int, kind : Int, data_a : Int, data_b : Int) -> Event {
  // Runtime version handshake: reject a stale Rust binary.
  if version != @nakake/gpui-bindings.ABI_VERSION {
    return Unknown
  }
  if kind == @nakake/gpui-bindings.EVENT_ASYNC {
    // data_a = token, data_b = byte length. Copy the payload from Rust's event
    // queue synchronously before returning from dispatch (it is valid only for
    // the duration of this call).
    Async(@nakake/gpui-bindings.copy_async_payload(data_a, data_b))
  } else {
    Unknown
  }
}

///|
fn dispatch(
  version : Int,
  kind : Int,
  view : Int,
  data_a : Int,
  data_b : Int,
) -> Int {
  let changed = apply_event(decode(version, kind, data_a, data_b))
  if changed == 1 {
    // Incremental path: update the one keyed text node in place. On failure
    // (tree not yet committed, key missing) fall back to the full `build_tree`,
    // which is always correct. Either way, returning `changed` (1) lets Rust
    // call `cx.notify()` so GPUI re-renders the (now updated) committed tree.
    match @nakake/gpui-bindings.update_text(view, LOG_KEY, current_log()) {
      Ok(_) => ()
      Err(_) =>
        match build_tree(view) {
          Ok(_) => ()
          Err(status) =>
            println(
              "stream: build_tree failed: \{@nakake/gpui-bindings.classify_status(status).to_string()}",
            )
        }
    }
  }
  changed
}

///|
fn apply_event(event : Event) -> Int {
  match event {
    Async(chunk) => on_async(chunk)
    Unknown => 0
  }
}

///|
fn on_async(chunk : Bytes) -> Int {
  if chunk.length() == 0 {
    return 0
  }
  // Decode lossily so a chunk split mid-codepoint (the producer frames bytes,
  // not characters) never aborts the handler; the replacement character marks
  // the boundary and the next chunk continues the stream.
  log.write_bytes(chunk.view())
  1
}

///|
fn current_log() -> String {
  @utf8.decode_lossy(log.to_bytes().view())
}

///|
fn build_tree(view : Int) -> Result[Unit, Int] {
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div() // root
  cb.set_bg(24, 26, 32)
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(20.0)
  cb.set_padding(32.0)

  cb.div()
  cb.set_font_weight(700)
  cb.text("Async Stream", 236, 239, 245, 26.0)
  cb.add_child()
  cb.add_child() // attach the title to the root

  // Log card: keyed so `update_text` can address its text child for the
  // incremental update; each injected chunk re-renders just this node.
  cb.div()
  cb.set_key(LOG_KEY)
  cb.set_bg_color(@nakake/gpui-bindings.Color::rgb(38, 42, 52))
  cb.set_padding(16.0)
  cb.set_border(2.0, 120, 200, 255)
  cb.set_rounded(12.0)
  let body = current_log()
  let shown = if body.is_empty() { "(waiting for events…)" } else { body }
  cb.text(shown, 160, 220, 255, 18.0)
  cb.add_child()
  cb.add_child() // attach the card to the root

  cb.text(
    "external producer: gpui_post_event(view, chunk, len)", 130, 135, 148, 14.0,
  )
  cb.add_child()

  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}

///|
fn main {
  // Install this app's dispatch into the library-owned entry point Rust links
  // (RFC 0004). Must happen before `run_window`.
  @nakake/gpui-bindings.register_dispatch(dispatch)
  match build_tree(0) {
    Ok(_) => ()
    Err(status) => abort("initial build_tree failed with status \{status}")
  }
  match @nakake/gpui-bindings.run_window(0, 520.0, 420.0) {
    Ok(_) => ()
    Err(status) => abort("run_window failed with status \{status}")
  }
}
