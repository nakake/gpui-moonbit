// Hello example: a minimal app different from Counter (issue #55 / G27).
//
// A static title, a status card that toggles ON/OFF, and one button.
// Events: button click toggles; the space bar toggles; Escape resets to OFF.
//
// This package is a library (like `app/`): `moon check` / `moon build` compile
// it, but producing an executable needs the Rust staticlib link that the root
// build driver prepares for `cmd/main` only. Making it a standalone executable
// means adding a `cmd/hello` entry with per-OS link templates and wiring it
// into build.sh (future work). `launch` below is the entry point such an
// executable calls.

// State lives in a typed store cell (RFC 0001 §3.3), not a top-level mutable
// array.

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let on : @nakake/gpui-bindings.CellId[Bool] = store.new_cell(false)

// Key codes = Unicode codepoint of a single-character key (sent by Rust).

///|
const KEY_SPACE : Int = 32 // ' ' → toggle

// Handler registry (RFC 0001 §3.2): the toggle button's closure is registered
// once; the issued id is written by `set_on_click` and routed back through
// `HandlerRegistry::dispatch`.

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = @nakake/gpui-bindings.HandlerRegistry::new()

///|
fn toggle() -> Int {
  store.set(on, !store.get(on))
  1
}

///|
let btn_toggle : Int = handlers.on_click(fn(_view) { ignore(toggle()) })

///|
fn on_key(code : Int, _mods : Int) -> Int {
  if code == KEY_SPACE {
    toggle()
  } else {
    0
  }
}

///|
fn on_named_key(id : Int, _mods : Int) -> Int {
  if id == @nakake/gpui-bindings.KEY_ESCAPE {
    if store.get(on) {
      store.set(on, false)
      1
    } else {
      0
    }
  } else {
    0
  }
}

// App-level handlers (key / named key reach the focused outer container, not a
// node): registered once, fanned out by the registry.

///|
let _key_handler : Int = handlers.on_key(fn(code, mods) { ignore(on_key(code, mods)) })

///|
let _named_key_handler : Int = handlers.on_named_key(fn(id, mods) {
  ignore(on_named_key(id, mods))
})

///|
pub fn dispatch(version : Int, kind : Int, view : Int, data_a : Int, data_b : Int) -> Int {
  // Runtime version handshake: a stale Rust binary is rejected before any
  // handler runs or the tree is touched.
  if version != @nakake/gpui-bindings.ABI_VERSION {
    return 0
  }
  handlers.dispatch(@nakake/gpui-bindings.decode_event(version, kind, data_a, data_b), view)
  // Phase A (RFC 0001 §5): handlers mutate `on` without reporting whether
  // anything changed, so every event rebuilds. Phase D replaces this gate with
  // signal dirty tracking (§3.4).
  match build_tree(view) {
    Ok(_) => ()
    Err(status) => println("hello: build_tree failed with status \{status}")
  }
  1
}

///|
pub fn build_tree(view : Int) -> Result[Unit, Int] {
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div() // root
  cb.set_bg(24, 26, 32)
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(24.0)
  cb.set_padding(40.0)

  cb.text("Hello, GPUI + MoonBit", 236, 239, 245, 28.0)
  cb.add_child()

  // Status card: keyed, bordered, padded, rounded.
  cb.div()
  cb.set_key("status-card")
  cb.set_padding(16.0)
  cb.set_border(2.0, 130, 220, 180)
  cb.set_rounded(12.0)
  let label = if store.get(on) { "Status: ON" } else { "Status: OFF" }
  cb.text(label, 130, 220, 180, 40.0)
  cb.add_child()
  cb.add_child() // attach the card to the root

  // One toggle button.
  cb.div()
  cb.set_key("btn-toggle")
  cb.set_size(160.0, 56.0)
  cb.set_bg(70, 110, 230)
  cb.set_rounded(10.0)
  cb.set_flex_col()
  cb.set_center()
  cb.set_on_click(btn_toggle)
  cb.text("Toggle", 255, 255, 255, 18.0)
  cb.add_child()
  cb.add_child() // attach the button to the root

  cb.text("keys:  space toggle    esc off", 130, 135, 148, 14.0)
  cb.add_child()

  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}

// Entry point for a future `cmd/hello` executable: retain `dispatch`, commit
// the initial tree, and block in the GPUI event loop.

///|
pub fn launch() -> Unit {
  // `dispatch` is only ever called from Rust (via its mangled symbol), which
  // MoonBit's dead-code elimination cannot see. The explicit function type both
  // retains it and anchors the five-Int / Int callback ABI during `moon check`.
  let _keep : (Int, Int, Int, Int, Int) -> Int = dispatch
  ignore(_keep)

  match build_tree(0) {
    Ok(_) => ()
    Err(status) => abort("initial build_tree failed with status \{status}")
  }
  match @nakake/gpui-bindings.run_window(0, 480.0, 420.0) {
    Ok(_) => ()
    Err(status) => abort("run_window failed with status \{status}")
  }
}
