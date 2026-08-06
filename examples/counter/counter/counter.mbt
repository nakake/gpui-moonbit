// Counter demo: the reference consumer app for nakake/gpui-bindings.
//
// This is a separate module that path-depends on the library (see moon.mod.json),
// so it exercises the exact route a third-party consumer takes: resolve the
// dependency, register a dispatch, and run.
//
// The app lives in this library package rather than in `main/` so it can carry
// unit tests: a package that imports `nakake/gpui-bindings/link` propagates the
// prebuild's link flags into its test executable too, and moon runs tests
// through tcc, which cannot resolve them. `main/` keeps the link import and
// nothing else.
//
// `dispatch` is the app's event entry point. Rust does not call it directly — it
// calls the library-owned `dispatch_entry`, which delegates to whatever `main`
// registered with `register_dispatch` (RFC 0004). The five i32 slots carry a
// versioned event envelope (docs/architecture.md §4b). The whole event loop —
// decode, typed handler dispatch, dirty detection, and rebuild scheduling — is
// the library's `framework_dispatch` (RFC 0001 §3.4): handlers `set` signals and
// never report "changed"; the framework rebuilds only when state actually moved.

// State lives in a typed store cell (RFC 0001 §3.3); handlers mutate it
// through the `count` signal (RFC 0001 §3.4), which is what the framework's
// dirty tracking observes.

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let count_cell : @nakake/gpui-bindings.CellId[Int] = store.new_cell(0)

///|
let count : @nakake/gpui-bindings.Signal[Int] = store.signal(count_cell)

// Stable key for the count display card's text node. `update_text` addresses it
// for the incremental in-place update (issue #10); the full `build_tree` path
// keys the same div so the two stay consistent.

///|
const COUNT_KEY : String = "count-label"

// Handler registry (RFC 0001 §3.2): closures are registered once at setup; the
// issued ids are written by `set_on_click` and routed back through
// `HandlerRegistry::dispatch`. No int constants, no int switch.

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = {
  // App-level handlers (key / named key / text reach the focused outer
  // container, not a node) are registered here, in `handlers`' own
  // initializer. They must NOT live in unreferenced top-level `let`s: MoonBit
  // only evaluates a top-level binding when something references it, so a
  // `_`-prefixed registration would be silently dropped and the handler never
  // fire. `handlers` is referenced by the click-handler lets, `ctx`, and the
  // tests, so building it always wires these registrations. Click handlers
  // stay as separate top-level `let`s because `button_row` references them by
  // name to write their ids into the wire stream; the text-input submit
  // handler follows the same pattern in `prompt_input`'s initializer
  // (`prompt_box` references it by name).
  let r = @nakake/gpui-bindings.HandlerRegistry::new()
  let _ = r.on_key(fn(code, mods) { on_key(code, mods) })
  let _ = r.on_named_key(fn(id, mods) { on_named_key(id, mods) })
  let _ = r.on_text(fn(text) { on_text(text) })
  r
}

///|
let btn_decrement : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(
  _view,
) {
  count.set(store, count.get(store) - 1)
})

///|
let btn_reset : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(_view) {
  count.set(store, 0)
})

///|
let btn_increment : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(
  _view,
) {
  count.set(store, count.get(store) + 1)
})

///|
let btn_increment_10 : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(
  _view,
) {
  count.set(store, count.get(store) + 10)
})

// Text input (RFC 0003): the prompt box's id is issued once and written into
// the wire stream by `prompt_box`; the submit handler is registered right
// there so evaluating `prompt_input` (which `build_tree` does) always wires
// it — the same keep-alive pattern as the click-handler lets. The handler
// closure captures the local `id` (not the top-level `prompt_input`) so the
// definition graph stays acyclic.

///|
let prompt_input : @nakake/gpui-bindings.InputId = {
  let id = handlers.new_input_id()
  handlers.on_submit(id, fn(view) { on_submit_input(view, id) })
  id
}

// Key codes = Unicode codepoint of a single-character key (sent by Rust).

///|
const KEY_K : Int = 107 // 'k' → +1

///|
const KEY_J : Int = 106 // 'j' → -1

///|
const KEY_R : Int = 114 // 'r' → reset

///|
fn on_key(code : Int, _mods : Int) -> Unit {
  if code == KEY_K {
    count.set(store, count.get(store) + 1)
  } else if code == KEY_J {
    count.set(store, count.get(store) - 1)
  } else if code == KEY_R {
    count.set(store, 0)
  }
}

// Named keys (Enter/Escape/arrows/…) arrive as an ABI id; the demo maps
// Enter/Up → +1, Down → -1, Escape → reset, mirroring k/j/r.

///|
fn on_named_key(id : Int, _mods : Int) -> Unit {
  if id == @nakake/gpui-bindings.KEY_ENTER || id == @nakake/gpui-bindings.KEY_UP {
    count.set(store, count.get(store) + 1)
  } else if id == @nakake/gpui-bindings.KEY_DOWN {
    count.set(store, count.get(store) - 1)
  } else if id == @nakake/gpui-bindings.KEY_ESCAPE {
    count.set(store, 0)
  }
}

// Text events carry typed characters (including IME-composed text). The demo
// treats a pure-digit string as "set count to N"; anything else is ignored.
// The parsed value is bounded by i32::MAX so a long digit run cannot wrap the
// 32-bit boundary silently (issue #81): once the next digit would overflow,
// the whole input is rejected rather than wrapping to a negative value. The
// same parser serves the text-input submit path (RFC 0003).

///|
fn parse_digits(text : String) -> Int? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for c in text {
    if c >= '0' && c <= '9' {
      let digit = c.to_int() - '0'.to_int()
      // Overflow guard: reject the input if the next digit would exceed
      // i32::MAX (0x7FFFFFFF), instead of letting `value * 10 + digit` wrap.
      if value > (0x7FFFFFFF - digit) / 10 {
        return None
      }
      value = value * 10 + digit
    } else {
      return None
    }
  }
  Some(value)
}

///|
fn on_text(text : String) -> Unit {
  match parse_digits(text) {
    Some(value) => count.set(store, value)
    None => ()
  }
}

// Submit from the text input (RFC 0003): pull the current text (the envelope
// carries only the input_id), parse it like `on_text`, and clear the box —
// Enter submits and empties, exactly like the harness prompt this demo
// mirrors. A pull failure (e.g. no committed model) leaves state untouched.

///|
fn on_submit_input(
  view : Int,
  input_id : @nakake/gpui-bindings.InputId,
) -> Unit {
  let text = match @nakake/gpui-bindings.input_text(view, input_id.to_int()) {
    Ok(t) => t
    Err(_) => return
  }
  match parse_digits(text) {
    Some(value) => count.set(store, value)
    None => ()
  }
  ignore(@nakake/gpui-bindings.input_set_text(view, input_id.to_int(), ""))
}

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
    fn(v) { update_count_view(v) },
  )
}

// The rebuild the framework schedules when state changed (RFC 0001 §3.4).
// Incremental path first (issue #10): the only state is `count`, and the only
// visible change is the count label text, so update that one keyed text node
// in place instead of re-encoding the whole tree. On any failure (tree not yet
// committed, key missing) fall back to the full `build_tree`, which is always
// correct.

///|
/// カウント表示カードのテキスト。インクリメンタル経路（`update_text`）とフルリビルド
/// 経路（`counter_card`）の両方がこれを使う。片方だけ書式を変えると、更新のたびに
/// 表示が揺れる（`update_text` が書いた文字列を次の `build_tree` が別物で上書きする）
/// ため、文字列は 1 箇所に閉じ込める。
fn count_label(n : Int) -> String {
  "Count: \{n}"
}

///|
/// インクリメンタル更新 → フルリビルドのフォールバック判断（issue #10）。実際の FFI
/// 呼び出しを引数で受け取るので、`moon test` からスタブを渡して分岐を検証できる
/// （`dispatch` 本体は FFI シンボルを参照するため `moon test` では走らない）。
/// 契約は 2 つ: `incremental` が成功したら `rebuild` を呼ばないこと、失敗したら
/// `rebuild` の結果をそのまま返すこと。
fn update_view_with(
  view : Int,
  incremental : (Int) -> Result[Unit, Int],
  rebuild : (Int) -> Result[Unit, Int],
) -> Result[Unit, Int] {
  match incremental(view) {
    Ok(_) => Ok(())
    Err(_) => rebuild(view)
  }
}

///|
fn update_count_view(view : Int) -> Result[Unit, Int] {
  update_view_with(
    view,
    fn(v) {
      @nakake/gpui-bindings.update_text(
        v,
        COUNT_KEY,
        count_label(count.get(store)),
      )
    },
    fn(v) { build_tree(v) },
  )
}

// --- Components (RFC 0001 §3.1) ---------------------------------------------
//
// `build_tree` is a sequence of component calls; each component emits its
// subtree onto the command buffer and leaves the subtree root on the stack so
// the caller attaches it with `add_child`.

///|
fn title(cb : @nakake/gpui-bindings.CommandBuffer) -> Unit {
  // A wrapper div carries the bold weight (G8 typography), inherited by the
  // text child.
  cb.div()
  cb.set_font_weight(700)
  cb.text("Counter", 236, 239, 245, 30.0)
  cb.add_child()
}

///|
fn counter_card(
  cb : @nakake/gpui-bindings.CommandBuffer,
  ctx : @nakake/gpui-bindings.RenderCtx,
) -> Unit {
  // Count display card: bordered, padded, rounded, with a soft shadow (G7/G9).
  // Keyed so `update_text` can address its text child for the incremental
  // in-place update (issue #10) without a full rebuild.
  cb.div()
  cb.set_key(COUNT_KEY)
  cb.set_bg_color(@nakake/gpui-bindings.Color::rgb(38, 42, 52))
  cb.set_padding(16.0)
  cb.set_border_color(2.0, @nakake/gpui-bindings.Color::rgb(120, 200, 255))
  cb.set_rounded(12.0)
  cb.set_shadow(0, 4, 8, 0, @nakake/gpui-bindings.Color::rgba(0, 0, 0, 96))
  cb.text(count_label(count.get(ctx.store)), 120, 200, 255, 44.0)
  cb.add_child()
}

///|
fn button_row(cb : @nakake/gpui-bindings.CommandBuffer) -> Unit {
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
  @nakake/gpui-bindings.button(cb, {
    key: "btn-decrement",
    label: "-1",
    color: @nakake/gpui-bindings.Color::rgb(200, 80, 80),
    on_click: btn_decrement,
  })
  cb.add_child()
  @nakake/gpui-bindings.button(cb, {
    key: "btn-reset",
    label: "Reset",
    color: @nakake/gpui-bindings.Color::rgb(92, 98, 110),
    on_click: btn_reset,
  })
  cb.add_child()
  @nakake/gpui-bindings.button(cb, {
    key: "btn-increment",
    label: "+1",
    color: @nakake/gpui-bindings.Color::rgb(70, 160, 95),
    on_click: btn_increment,
  })
  cb.add_child()
  @nakake/gpui-bindings.button(cb, {
    key: "btn-increment-10",
    label: "+10",
    color: @nakake/gpui-bindings.Color::rgb(70, 110, 230),
    on_click: btn_increment_10,
  })
  cb.add_child()
  cb.add_child() // attach the row to the scroll container
}

///|
fn prompt_box(cb : @nakake/gpui-bindings.CommandBuffer) -> Unit {
  // Editable single-line input (RFC 0003): the Rust-side text model keeps the
  // buffer/selection/preedit across rebuilds; the demo pulls on submit only.
  // `min_width` is required: the root column is centered, so the frame shrinks
  // to its content and the inner leaf's 100% width would resolve to 0.
  @nakake/gpui-bindings.text_input(cb, {
    key: "prompt-input",
    input_id: prompt_input,
    placeholder: "type a number, press Enter",
    min_width: 360,
  })
}

///|
fn key_hints(cb : @nakake/gpui-bindings.CommandBuffer) -> Unit {
  cb.text("keys:  k +1    j -1    r reset", 130, 135, 148, 14.0)
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

  title(cb)
  cb.add_child()
  counter_card(cb, ctx)
  cb.add_child()
  button_row(cb)
  cb.add_child()
  prompt_box(cb)
  cb.add_child()
  key_hints(cb)
  cb.add_child()

  cb.set_root()
  @nakake/gpui-bindings.build_tree(view, cb)
}
