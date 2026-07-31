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

///|
let on : Array[Bool] = [false]

// Button click id (the single clickable div carries it; routed in `on_click`).

///|
const BTN_TOGGLE : Int = 1

// Key codes = Unicode codepoint of a single-character key (sent by Rust).

///|
const KEY_SPACE : Int = 32 // ' ' → toggle

///|
priv enum Event {
  Click(Int) // click_id
  Key(Int, Int) // codepoint, modifier bits
  NamedKey(Int, Int) // named_key_id, modifier bits
  Unknown
}

///|
fn decode(version : Int, kind : Int, data_a : Int, data_b : Int) -> Event {
  // Runtime version handshake: reject a stale Rust binary.
  if version != @nakake/gpui-bindings.ABI_VERSION {
    return Unknown
  }
  if kind == @nakake/gpui-bindings.EVENT_CLICK {
    Click(data_a)
  } else if kind == @nakake/gpui-bindings.EVENT_KEY {
    Key(data_a, data_b)
  } else if kind == @nakake/gpui-bindings.EVENT_NAMED_KEY {
    NamedKey(data_a, data_b)
  } else {
    Unknown
  }
}

///|
pub fn dispatch(version : Int, kind : Int, view : Int, data_a : Int, data_b : Int) -> Int {
  let changed = apply_event(decode(version, kind, data_a, data_b))
  if changed == 1 {
    // Rebuild the tree. On failure the Rust side keeps the old committed tree
    // (atomic commit), so returning `changed` still lets GPUI re-render it.
    match build_tree(view) {
      Ok(_) => ()
      Err(status) => println("hello: build_tree failed with status \{status}")
    }
  }
  changed
}

///|
fn apply_event(event : Event) -> Int {
  match event {
    Click(click_id) => on_click(click_id)
    Key(code, mods) => on_key(code, mods)
    NamedKey(id, mods) => on_named_key(id, mods)
    Unknown => 0
  }
}

///|
fn toggle() -> Int {
  on[0] = if on[0] { false } else { true }
  1
}

///|
fn on_click(click_id : Int) -> Int {
  if click_id == BTN_TOGGLE {
    toggle()
  } else {
    0
  }
}

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
    if on[0] {
      on[0] = false
      1
    } else {
      0
    }
  } else {
    0
  }
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
  let label = if on[0] { "Status: ON" } else { "Status: OFF" }
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
  cb.set_on_click(BTN_TOGGLE)
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
