// Minimal runner for the build driver (issue #125, RFC 0004 §4).
//
// The Counter demo now lives in `examples/counter` — a separate module that
// consumes the library the way a third party does, which is the whole point of
// the registration model. What stays here is the smallest program that still
// links the Rust staticlib end to end, because the build driver needs one:
// `build.sh` extracts the callback symbol from this executable's generated C
// ([2/5]) and re-links it against `libgpui_sys.a` ([4/6]).
//
// So it stays a real app, not a stub: it registers a dispatch, opens a window,
// and moves state on click and on a key press. If events stop flowing, running
// this is the first thing that shows it.

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let hits_cell : @nakake/gpui-bindings.CellId[Int] = store.new_cell(0)

///|
let hits : @nakake/gpui-bindings.Signal[Int] = store.signal(hits_cell)

// Stable key for the counter card, addressed by `update_text` for the in-place
// update; the full rebuild keys the same div so both paths agree.

///|
const HITS_KEY : String = "hits-label"

///|
const KEY_SPACE : Int = 32 // ' ' → count a hit

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = {
  // Registered inside `handlers`' own initializer: MoonBit only evaluates a
  // top-level binding when something references it, so a `_`-prefixed top-level
  // registration would be dropped and the handler would never fire.
  let r = @nakake/gpui-bindings.HandlerRegistry::new()
  let _ = r.on_key(fn(code, _mods) {
    if code == KEY_SPACE {
      hits.set(store, hits.get(store) + 1)
    }
  })
  r
}

///|
let btn_hit : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(_view) {
  hits.set(store, hits.get(store) + 1)
})

///|
let ctx : @nakake/gpui-bindings.RenderCtx = { view: 0, store, handlers }

///|
fn hits_label(n : Int) -> String {
  "events received: \{n}"
}

///|
fn build_tree(view : Int) -> Result[Unit, Int] {
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div() // root
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(24.0)
  cb.set_padding(32.0)
  cb.div()
  cb.set_font_weight(700)
  cb.text("gpui-bindings runner", 236, 239, 245, 26.0)
  cb.add_child()
  cb.add_child()
  cb.div()
  cb.set_key(HITS_KEY)
  cb.set_padding(16.0)
  cb.set_rounded(12.0)
  cb.set_border_color(2.0, @nakake/gpui-bindings.Color::rgb(120, 200, 255))
  cb.text(hits_label(hits.get(store)), 120, 200, 255, 28.0)
  cb.add_child()
  cb.add_child()
  @nakake/gpui-bindings.button(cb, {
    key: "btn-hit",
    label: "click",
    color: @nakake/gpui-bindings.Color::rgb(70, 160, 95),
    on_click: btn_hit,
  })
  cb.add_child()
  cb.text(
    "the demo app lives in examples/counter", 130, 135, 148, 14.0,
  )
  cb.add_child()
  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}

///|
fn dispatch(
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
    // Incremental update first, full rebuild on failure (issue #10).
    fn(v) {
      match
        @nakake/gpui-bindings.update_text(
          v, HITS_KEY, hits_label(hits.get(store)),
        ) {
        Ok(_) => Ok(())
        Err(_) => build_tree(v)
      }
    },
  )
}

///|
fn main {
  // Install this app's dispatch into the library-owned entry point Rust links
  // (RFC 0004). Registration must happen before `run_window`, and the parameter
  // type anchors the five-Int / Int callback ABI (versioned event envelope:
  // abi_version, event_kind, view, data_a, data_b) during `moon check`.
  @nakake/gpui-bindings.register_dispatch(dispatch)
  @nakake/gpui-bindings.expect_ok(build_tree(0), "initial build_tree")
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings.run_window(0, 600.0, 500.0),
    "run_window",
  )
}
