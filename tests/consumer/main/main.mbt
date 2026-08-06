// Consumer smoke test on the library's framework layer (issue #125, RFC 0004
// §6-1).
//
// This module depends on nakake/gpui-bindings by path and imports the link-only
// package, so building it exercises the whole prebuild path: build.py runs,
// cargo builds the Rust staticlib, and the LinkConfig it emits has to be good
// enough for the platform linker. It must actually *call* into the staticlib —
// a program that only imports the bindings would link even with broken flags,
// because nothing pulls an object out of the archive.
//
// On top of that (the reason this file exists), it is now a real consumer: it
// builds its own tiny app on the framework layer (Store / Signal /
// HandlerRegistry), registers it as the library-owned dispatch entry point
// (RFC 0004), and drives it by injecting events through `dispatch_entry`. Each
// injection asserts both the entry's return value (0 = nothing changed /
// 1 = redraw) and the app's own state, so a routing or dirty-tracking bug fails
// the build rather than silently skipping a repaint.
//
// Headless, so no window is opened. That does not make the FFI a no-op:
// `build_tree` commits into the process-global view table and succeeds
// (gpui-sys/src/lib.rs), so the rebuild the framework schedules is asserted to
// have been accepted. `input_text` is the opposite case — it reads the
// text-input mirror, which no tree here populates, so it returns
// GPUI_STATUS_INVALID_HANDLE (-1) instead of a string.

// The app's state: a typed counter cell behind a subscribable signal.
// Handlers mutate it only through `count.set(store, ...)`; they never report a
// "changed" flag, the framework decides that from the store's dirty tracking
// (RFC 0001 §3.4).

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let count_cell : @nakake/gpui-bindings.CellId[Int] = store.new_cell(0)

///|
let count : @nakake/gpui-bindings.Signal[Int] = store.signal(count_cell)

// Key code for 'k'. Kept behind a named constant so the injection site reads
// like the key route it exercises.

///|
const KEY_K : Int = 107 // 'k'

// The handler registry. The key and named-key handlers are registered INSIDE
// this initializer (not as `_`-prefixed top-level lets): MoonBit only evaluates
// a top-level binding when something references it, so a `_`-prefixed
// registration would be silently dropped and the handler would never fire.

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = {
  let r = @nakake/gpui-bindings.HandlerRegistry::new()
  let _ = r.on_key(fn(code, _mods) {
    if code == KEY_K {
      count.set(store, count.get(store) + 10)
    }
  })
  let _ = r.on_named_key(fn(id, _mods) {
    if id == @nakake/gpui-bindings.KEY_ESCAPE {
      count.set(store, 0)
    }
  })
  r
}

// The two click handlers, as top-level HandlerIds so the test can replay their
// registry-issued ids. All four deltas are deliberately different
// (+1 / -1 / +10 / reset): if an event were routed to the wrong handler the
// assertions below would still see a wrong number, so a routing bug cannot pass
// by coincidence.

///|
let btn_increment : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(
  _view,
) {
  count.set(store, count.get(store) + 1)
})

///|
let btn_decrement : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(
  _view,
) {
  count.set(store, count.get(store) - 1)
})

// Render context glued to view 0 (headless, never opened).

///|
let ctx : @nakake/gpui-bindings.RenderCtx = { view: 0, store, handlers }

// How many times the framework asked for a rebuild.

///|
let rebuilds : Ref[Int] = { val: 0 }

// The last non-OK status a rebuild came back with, or 0 if every rebuild was
// accepted. The framework ignores the rebuild's `Result` (RFC 0001 §3.4), so
// without recording it here a consumer whose tree Rust rejects would still see
// this test pass.

///|
let rebuild_error : Ref[Int] = { val: 0 }

///|
fn app_build_tree(view : Int) -> Result[Unit, Int] {
  // A minimal tree: a flex-column root div with one counter text child.
  // Headless this still succeeds — `build_tree` commits the tree into the view
  // table without needing a window — so it is a real end-to-end check of the
  // wire buffer this app encodes.
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div()
  cb.set_flex_col()
  cb.text("count: \{count.get(store)}", 120, 200, 255, 24.0)
  cb.add_child()
  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}

///|
fn app_dispatch(
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
    fn(v) {
      rebuilds.val = rebuilds.val + 1
      let result = app_build_tree(v)
      match result {
        Ok(_) => ()
        Err(status) => rebuild_error.val = status
      }
      result
    },
  )
}

///|
fn main {
  // Register a dispatch so the staticlib's mb_dispatch reference resolves to
  // the library's entry point (RFC 0004). No `_keep` binding: registering is
  // what retains `dispatch_entry` through dead-code elimination.
  @nakake/gpui-bindings.register_dispatch(app_dispatch)

  // One small local helper for every injection, and one that asserts with a
  // step-naming abort so a CI failure says exactly which injection broke.
  fn send(kind : Int, data_a : Int, data_b : Int) -> Int {
    @nakake/gpui-bindings.dispatch_entry(
      @nakake/gpui-bindings.ABI_VERSION, kind, 0, data_a, data_b,
    )
  }
  fn expect(
    label : String,
    changed : Int,
    want_changed : Int,
    want_count : Int,
  ) -> Unit {
    if changed != want_changed {
      abort(
        "\{label}: dispatch_entry returned \{changed}, want \{want_changed}; count is \{count.get(store)}",
      )
    }
    let observed = count.get(store)
    if observed != want_count {
      abort(
        "\{label}: count is \{observed}, want \{want_count} (dispatch returned \{changed})",
      )
    }
  }

  // The injection sequence. Steps 1..5 change state and must each report 1
  // (redraw); steps 6-8 must report 0.
  //
  // Steps 6/7 prove the dirty gate from both sides: step 6 is an event no
  // handler claims (the click id was never issued, so the registry resolves no
  // closure) and step 7 is a handler that does run but sets nothing (the
  // named-key handler ignores Tab). Both must report "no change" so Rust does
  // not repaint.
  // Step 8 is the version handshake: a stale Rust binary is rejected before any
  // handler runs.
  expect("step1 click increment", send(
    @nakake/gpui-bindings.EVENT_CLICK, btn_increment.to_int(), 0,
  ), 1, 1)
  expect("step2 click increment", send(
    @nakake/gpui-bindings.EVENT_CLICK, btn_increment.to_int(), 0,
  ), 1, 2)
  expect("step3 key 'k'", send(@nakake/gpui-bindings.EVENT_KEY, KEY_K, 0), 1, 12)
  expect("step4 click decrement", send(
    @nakake/gpui-bindings.EVENT_CLICK, btn_decrement.to_int(), 0,
  ), 1, 11)
  expect("step5 named-key escape", send(
    @nakake/gpui-bindings.EVENT_NAMED_KEY, @nakake/gpui-bindings.KEY_ESCAPE, 0,
  ), 1, 0)
  expect("step6 unknown click id", send(
    @nakake/gpui-bindings.EVENT_CLICK, 9999, 0,
  ), 0, 0)
  expect("step7 unhandled named-key tab", send(
    @nakake/gpui-bindings.EVENT_NAMED_KEY, @nakake/gpui-bindings.KEY_TAB, 0,
  ), 0, 0)
  // Step 8: the version handshake. A stale ABI must short-circuit to 0 without
  // touching state.
  expect(
    "step8 stale abi",
    @nakake/gpui-bindings.dispatch_entry(
      @nakake/gpui-bindings.ABI_VERSION + 1,
      @nakake/gpui-bindings.EVENT_CLICK,
      0,
      btn_increment.to_int(),
      0,
    ),
    0,
    0,
  )

  // Steps 1-5 each dirtied the store and must have asked for exactly one
  // rebuild; steps 6-8 must not have asked at all.
  if rebuilds.val != 5 {
    abort("rebuilds = \{rebuilds.val}, want 5 (one per state-changing injection)")
  }
  // Every one of those rebuilds crossed the FFI and had its tree accepted.
  if rebuild_error.val != 0 {
    abort("a rebuild's build_tree returned \{rebuild_error.val}, want 0 (OK)")
  }

  // Serialize a small tree — pure MoonBit, no FFI yet. This is why the test
  // exists (issue #103: prebuild link-flag propagation): a non-empty wire
  // buffer proves the encoder is wired up.
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div()
  cb.text("consumer smoke", 255, 255, 255, 16.0)
  cb.add_child()
  cb.set_root()
  let wire = cb.to_bytes()
  if wire.length() == 0 {
    abort("CommandBuffer produced an empty wire buffer")
  }

  // Cross the FFI boundary: this is what forces the linker to resolve gpui_sys
  // and every native library the prebuild reported.
  match @nakake/gpui-bindings.input_text(0, 0) {
    Ok(text) => abort("input_text unexpectedly succeeded headless: '\{text}'")
    Err(status) =>
      if status != -1 {
        abort("input_text returned \{status}, want -1 (INVALID_HANDLE)")
      }
  }
  println(
    "PASS: consumer app driven by injected events (\{wire.length()} bytes serialized, \{rebuilds.val} rebuilds)",
  )
}