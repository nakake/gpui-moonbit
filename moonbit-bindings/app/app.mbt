// Interactive app: state + logic, written in MoonBit.
//
// `dispatch` is the single event entry point that Rust (gpui-sys) calls via its
// compiled symbol. The five i32 slots carry a versioned event envelope
// (docs/architecture.md §4b); decoding into a typed `Event` and dispatching to
// typed handler closures live in the gpui-bindings library (RFC 0001 §3.2).
// This file registers its handlers with a `HandlerRegistry` once at setup and
// writes the issued ids into the tree via `set_on_click`.
//
// NOTE: changing `dispatch`'s signature does NOT change the mangled symbol name
// (MoonBit mangling excludes types), so the Rust `extern` must be kept in sync —
// it is generated from a template in `gpui-sys/build.rs`.

// State lives in a typed store cell (RFC 0001 §3.3), not a top-level mutable
// array: `count` is a `CellId[Int]` and every read/write goes through the
// store, so the value type is fixed by the id and the pattern scales to
// multiple cells / components.

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let count : @nakake/gpui-bindings.CellId[Int] = store.new_cell(0)

// Stable key for the count display card's text node. `update_text` addresses it
// for the incremental in-place update (issue #10); the full `build_tree` path
// keys the same div so the two stay consistent.

///|
const COUNT_KEY : String = "count-label"

// Handler registry (RFC 0001 §3.2): closures are registered once at setup; the
// issued ids are written by `set_on_click` and routed back through
// `HandlerRegistry::dispatch`. No int constants, no int switch.

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = @nakake/gpui-bindings.HandlerRegistry::new()

///|
let btn_decrement : Int = handlers.on_click(fn(_view) {
  store.set(count, store.get(count) - 1)
})

///|
let btn_reset : Int = handlers.on_click(fn(_view) { ignore(reset_count()) })

///|
let btn_increment : Int = handlers.on_click(fn(_view) {
  store.set(count, store.get(count) + 1)
})

///|
let btn_increment_10 : Int = handlers.on_click(fn(_view) {
  store.set(count, store.get(count) + 10)
})

// Key codes = Unicode codepoint of a single-character key (sent by Rust).

///|
const KEY_K : Int = 107 // 'k' → +1

///|
const KEY_J : Int = 106 // 'j' → -1

///|
const KEY_R : Int = 114 // 'r' → reset

///|
fn reset_count() -> Int {
  if store.get(count) == 0 {
    0
  } else {
    store.set(count, 0)
    1
  }
}

///|
fn on_key(code : Int, _mods : Int) -> Int {
  if code == KEY_K {
    store.set(count, store.get(count) + 1)
    1
  } else if code == KEY_J {
    store.set(count, store.get(count) - 1)
    1
  } else if code == KEY_R {
    reset_count()
  } else {
    0
  }
}

// Named keys (Enter/Escape/arrows/…) arrive as an ABI id; the demo maps
// Enter/Up → +1, Down → -1, Escape → reset, mirroring k/j/r.

///|
fn on_named_key(id : Int, _mods : Int) -> Int {
  if id == @nakake/gpui-bindings.KEY_ENTER || id == @nakake/gpui-bindings.KEY_UP {
    store.set(count, store.get(count) + 1)
    1
  } else if id == @nakake/gpui-bindings.KEY_DOWN {
    store.set(count, store.get(count) - 1)
    1
  } else if id == @nakake/gpui-bindings.KEY_ESCAPE {
    reset_count()
  } else {
    0
  }
}

// Text events carry typed characters (including IME-composed text). The demo
// treats a pure-digit string as "set count to N"; anything else is ignored.

///|
fn on_text(text : String) -> Int {
  if text.is_empty() {
    return 0
  }
  // Accept only ASCII digits so the demo stays deterministic across locales.
  let mut value = 0
  let mut all_digits = true
  for c in text {
    if c >= '0' && c <= '9' {
      value = value * 10 + (c.to_int() - '0'.to_int())
    } else {
      all_digits = false
      break
    }
  }
  if all_digits && value != store.get(count) {
    store.set(count, value)
    1
  } else {
    0
  }
}

// App-level handlers (key / named key / text reach the focused outer
// container, not a node): registered once, fanned out by the registry.

///|
let _key_handler : Int = handlers.on_key(fn(code, mods) { ignore(on_key(code, mods)) })

///|
let _named_key_handler : Int = handlers.on_named_key(fn(id, mods) {
  ignore(on_named_key(id, mods))
})

///|
let _text_handler : Int = handlers.on_text(fn(text) { ignore(on_text(text)) })

///|
pub fn dispatch(version : Int, kind : Int, view : Int, data_a : Int, data_b : Int) -> Int {
  // Runtime version handshake: a stale Rust binary is rejected before any
  // handler runs or the tree is touched.
  if version != @nakake/gpui-bindings.ABI_VERSION {
    return 0
  }
  handlers.dispatch(@nakake/gpui-bindings.decode_event(version, kind, data_a, data_b), view)
  // Phase A (RFC 0001 §5): handlers mutate `count` without reporting whether
  // anything changed, so every event triggers the update path. Phase D
  // replaces this gate with signal dirty tracking (§3.4), which restores
  // "rebuild only on real change" declaratively.
  // Incremental path (issue #10): the only state is `count`, and the only
  // visible change is the count label text. Update that one keyed text node
  // in place instead of re-encoding and re-decoding the whole tree. On any
  // failure (tree not yet committed, key missing) fall back to the full
  // `build_tree`, which is always correct. Either way, returning 1 lets Rust
  // call `cx.notify()` so GPUI re-renders the (now updated) committed tree.
  match @nakake/gpui-bindings.update_text(view, COUNT_KEY, "Count: \{store.get(count)}") {
    Ok(_) => ()
    Err(_) =>
      match build_tree(view) {
        Ok(_) => ()
        Err(status) => println(
          "app: build_tree failed: \{@nakake/gpui-bindings.classify_status(status).to_string()}",
        )
      }
  }
  1
}

// Build one labelled, clickable button onto the command buffer. The button div
// is pushed, configured, given a text label child, and left on the stack so the
// caller can `add_child` it into its parent.

///|
fn make_button(
  cb : @nakake/gpui-bindings.CommandBuffer,
  key : String,
  label : String,
  click_id : Int,
  r : Int,
  g : Int,
  b : Int,
) -> Unit {
  cb.div()
  cb.set_key(key)
  cb.set_size(92.0, 56.0)
  cb.set_bg(r, g, b)
  cb.set_rounded(10.0)
  cb.set_flex_col()
  cb.set_center()
  cb.set_on_click(click_id)
  cb.text(label, 255, 255, 255, 18.0)
  cb.add_child() // attach the label to the button; button stays on top
}

///|
pub fn build_tree(view : Int) -> Result[Unit, Int] {
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div() // root
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(28.0)
  cb.set_padding(32.0)

  // Title: a wrapper div carries the bold weight (G8 typography), inherited by
  // the text child.
  cb.div()
  cb.set_font_weight(700)
  cb.text("Counter", 236, 239, 245, 30.0)
  cb.add_child()
  cb.add_child() // attach the title wrapper to the root

  // Count display card: bordered, padded, rounded, with a soft shadow (G7/G9).
  // Keyed so `update_text` can address its text child for the incremental
  // in-place update (issue #10) without a full rebuild.
  cb.div()
  cb.set_key(COUNT_KEY)
  cb.set_bg_color(@nakake/gpui-bindings.Color::rgb(38, 42, 52))
  cb.set_padding(16.0)
  cb.set_border(2.0, 120, 200, 255)
  cb.set_rounded(12.0)
  cb.set_shadow(0, 4, 8, 0, @nakake/gpui-bindings.Color::rgba(0, 0, 0, 96))
  cb.text("Count: \{store.get(count)}", 120, 200, 255, 44.0)
  cb.add_child()
  cb.add_child() // attach the card to the root

  // A row of buttons; each carries a registry-issued handler id. The row sits
  // inside a keyed horizontal-scroll container (G6): its retained ScrollHandle
  // keeps the scroll position across the rebuild every click triggers. The
  // 404px row (4×92 + 3×12 gap) overflows the 300px container, so the wheel
  // scrolls it sideways (a vertical wheel maps to the x-axis when only x
  // scrolls).
  cb.div() // scroll container
  cb.set_key("button-scroll")
  cb.set_size(300.0, 60.0)
  cb.set_overflow(
    @nakake/gpui-bindings.OVERFLOW_SCROLL,
    @nakake/gpui-bindings.OVERFLOW_VISIBLE,
  )
  cb.div() // row
  cb.set_size(404.0, 56.0) // wider than the 300px container → horizontal overflow
  cb.set_flex_row()
  cb.set_gap(12.0)
  make_button(cb, "btn-decrement", "-1", btn_decrement, 200, 80, 80)
  cb.add_child()
  make_button(cb, "btn-reset", "Reset", btn_reset, 92, 98, 110)
  cb.add_child()
  make_button(cb, "btn-increment", "+1", btn_increment, 70, 160, 95)
  cb.add_child()
  make_button(cb, "btn-increment-10", "+10", btn_increment_10, 70, 110, 230)
  cb.add_child()
  cb.add_child() // attach the row to the scroll container
  cb.add_child() // attach the scroll container to the root

  cb.text("keys:  k +1    j -1    r reset", 130, 135, 148, 14.0)
  cb.add_child()

  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}
