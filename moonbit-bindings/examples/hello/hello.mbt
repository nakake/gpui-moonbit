// Hello example: a minimal app different from Counter (issue #55 / G27).
//
// A static title, a status card that toggles ON/OFF, and one button.
// Events: button click toggles; the space bar toggles; Escape resets to OFF.
//
// The event loop is the library's `framework_dispatch` (RFC 0001 §3.4):
// handlers `set` the `on` signal and never report "changed"; the framework
// rebuilds only when state actually moved.
//
// This package is a library (like `app/`): `moon check` / `moon build` compile
// it, but producing an executable needs the Rust staticlib link that the root
// build driver prepares for `cmd/main` only. Making it a standalone executable
// means adding a `cmd/hello` entry with per-OS link templates and wiring it
// into build.sh (future work). `launch` below is the entry point such an
// executable calls.

// State lives in a typed store cell (RFC 0001 §3.3); handlers mutate it
// through the `on` signal (RFC 0001 §3.4).

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let on_cell : @nakake/gpui-bindings.CellId[Bool] = store.new_cell(false)

///|
let on : @nakake/gpui-bindings.Signal[Bool] = store.signal(on_cell)

// Key codes = Unicode codepoint of a single-character key (sent by Rust).

///|
const KEY_SPACE : Int = 32 // ' ' → toggle

// Handler registry (RFC 0001 §3.2): the toggle button's closure is registered
// once; the issued id is written by `set_on_click` and routed back through
// `HandlerRegistry::dispatch`.

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = @nakake/gpui-bindings.HandlerRegistry::new()

///|
let btn_toggle : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(_view) {
  on.set(store, !on.get(store))
})

///|
fn on_key(code : Int, _mods : Int) -> Unit {
  if code == KEY_SPACE {
    on.set(store, !on.get(store))
  }
}

///|
fn on_named_key(id : Int, _mods : Int) -> Unit {
  if id == @nakake/gpui-bindings.KEY_ESCAPE {
    on.set(store, false)
  }
}

// App-level handlers (key / named key reach the focused outer container, not a
// node): registered once, fanned out by the registry.

///|
let _key_handler : Int = handlers.on_key(fn(code, mods) { on_key(code, mods) })

///|
let _named_key_handler : Int = handlers.on_named_key(fn(id, mods) {
  on_named_key(id, mods)
})

// Render context (RFC 0001 §3.1): components reach the store and handler
// registry through it. `view` is fixed to slot 0 (the single window).

///|
let ctx : @nakake/gpui-bindings.RenderCtx = { view: 0, store, handlers }

///|
pub fn dispatch(
  version : Int,
  kind : Int,
  view : Int,
  data_a : Int,
  data_b : Int,
) -> Int {
  @nakake/gpui-bindings.framework_dispatch(
    ctx,
    version,
    kind,
    view,
    data_a,
    data_b,
    fn(v) { build_tree(v) },
  )
}

// --- Components (RFC 0001 §3.1) ---------------------------------------------
//
// `build_tree` is a sequence of component calls; each component emits its
// subtree onto the command buffer and leaves the subtree root on the stack so
// the caller attaches it with `add_child`.

///|
fn status_card(
  cb : @nakake/gpui-bindings.CommandBuffer,
  ctx : @nakake/gpui-bindings.RenderCtx,
) -> Unit {
  // Status card: keyed, bordered, padded, rounded.
  cb.div()
  cb.set_key("status-card")
  cb.set_padding(16.0)
  cb.set_border_color(2.0, @nakake/gpui-bindings.Color::rgb(130, 220, 180))
  cb.set_rounded(12.0)
  let label = if on.get(ctx.store) { "Status: ON" } else { "Status: OFF" }
  cb.text(label, 130, 220, 180, 40.0)
  cb.add_child()
}

///|
fn toggle_button(cb : @nakake/gpui-bindings.CommandBuffer) -> Unit {
  // Wider than the library `button` component's fixed 92px, so this example
  // keeps a local component with its own size.
  cb.div()
  cb.set_key("btn-toggle")
  cb.set_size(160.0, 56.0)
  cb.set_bg(70, 110, 230)
  cb.set_rounded(10.0)
  cb.set_flex_col()
  cb.set_center()
  cb.set_on_click(btn_toggle.to_int())
  cb.text("Toggle", 255, 255, 255, 18.0)
  cb.add_child()
}

///|
fn key_hints(cb : @nakake/gpui-bindings.CommandBuffer) -> Unit {
  cb.text("keys:  space toggle    esc off", 130, 135, 148, 14.0)
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
  status_card(cb, ctx)
  cb.add_child()
  toggle_button(cb)
  cb.add_child()
  key_hints(cb)
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
