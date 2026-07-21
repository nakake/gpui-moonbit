// Interactive app: state + logic, written in MoonBit.
//
// `dispatch` is the single event entry point that Rust (gpui-sys) calls via its
// compiled symbol. It takes a small scalar payload — `kind` selects the event
// type, and `id`/`a`/`b` carry per-kind data. The FFI surface stays fixed at ONE
// symbol no matter how many event types (or buttons) we add: new kinds are
// handled by extending the `Event` enum here, and new buttons are just new
// `click_id`s routed in `on_click` — neither needs any Rust/FFI change.
//
// NOTE: changing `dispatch`'s signature does NOT change the mangled symbol name
// (MoonBit mangling excludes types), so the Rust `extern` must be kept in sync —
// it is generated from a template in `gpui-sys/build.rs`.

///|
let count : Array[Int] = [0]

// Button click ids (each clickable div carries one; routed in `on_click`).

///|
const BTN_DECREMENT : Int = 1

///|
const BTN_RESET : Int = 2

///|
const BTN_INCREMENT : Int = 3

///|
const BTN_INCREMENT_10 : Int = 4

///|
priv enum Event {
  Click(Int) // click_id
  Key(Int, Int) // codepoint, modifier bits
  Unknown
}

///|
fn decode(kind : Int, id : Int, a : Int, b : Int) -> Event {
  // Int 定数の比較。const 名を match のパターンにすると束縛と紛れるので if で比較。
  if kind == @username/gpui-bindings.EVENT_CLICK {
    Click(id)
  } else if kind == @username/gpui-bindings.EVENT_KEY {
    Key(a, b)
  } else {
    Unknown
  }
}

///|
pub fn dispatch(kind : Int, id : Int, a : Int, b : Int) -> Int {
  rebuild_if_changed(apply_event(decode(kind, id, a, b)), build_tree)
}

///|
fn apply_event(event : Event) -> Int {
  match event {
    Click(click_id) => on_click(click_id)
    Key(code, mods) => on_key(code, mods)
    Unknown => 0
  }
}

///|
fn rebuild_if_changed(changed : Int, rebuild : () -> Unit) -> Int {
  if changed == 1 {
    rebuild()
  }
  changed
}

///|
fn on_click(click_id : Int) -> Int {
  if click_id == BTN_DECREMENT {
    count[0] = count[0] - 1
    1
  } else if click_id == BTN_RESET {
    reset_count()
  } else if click_id == BTN_INCREMENT {
    count[0] = count[0] + 1
    1
  } else if click_id == BTN_INCREMENT_10 {
    count[0] = count[0] + 10
    1
  } else {
    0
  }
}

// Key codes = Unicode codepoint of a single-character key (sent by Rust).

///|
const KEY_K : Int = 107 // 'k' → +1

///|
const KEY_J : Int = 106 // 'j' → -1

///|
const KEY_R : Int = 114 // 'r' → reset

///|
fn reset_count() -> Int {
  if count[0] == 0 {
    0
  } else {
    count[0] = 0
    1
  }
}

///|
fn on_key(code : Int, _mods : Int) -> Int {
  if code == KEY_K {
    count[0] = count[0] + 1
    1
  } else if code == KEY_J {
    count[0] = count[0] - 1
    1
  } else if code == KEY_R {
    reset_count()
  } else {
    0
  }
}

// Build one labelled, clickable button and return its handle.

///|
fn make_button(
  key : String,
  label : String,
  click_id : Int,
  r : Int,
  g : Int,
  b : Int,
) -> @username/gpui-bindings.NodeHandle {
  let btn = @username/gpui-bindings.create_div()
  ignore(@username/gpui-bindings.set_key(btn, key))
  ignore(@username/gpui-bindings.set_size(btn, 92.0, 56.0))
  ignore(@username/gpui-bindings.set_bg(btn, r, g, b))
  ignore(@username/gpui-bindings.set_rounded(btn, 10.0))
  ignore(@username/gpui-bindings.set_flex_col(btn))
  ignore(@username/gpui-bindings.set_center(btn))
  ignore(@username/gpui-bindings.set_on_click(btn, click_id))
  let lbl = @username/gpui-bindings.create_text(label, 255, 255, 255, 18.0)
  ignore(@username/gpui-bindings.add_child(btn, lbl))
  btn
}

///|
pub fn build_tree() -> Unit {
  @username/gpui-bindings.begin_tree(0)
  let root = @username/gpui-bindings.create_div()
  ignore(@username/gpui-bindings.set_bg(root, 28, 30, 38))
  ignore(@username/gpui-bindings.set_flex_col(root))
  ignore(@username/gpui-bindings.set_center(root))
  ignore(@username/gpui-bindings.set_gap(root, 28.0))
  let title = @username/gpui-bindings.create_text(
    "Counter", 236, 239, 245, 30.0,
  )
  ignore(@username/gpui-bindings.add_child(root, title))
  let value = @username/gpui-bindings.create_text(
    "Count: \{count[0]}",
    120,
    200,
    255,
    44.0,
  )
  ignore(@username/gpui-bindings.add_child(root, value))

  // A row of buttons; each is just a distinct click_id routed in on_click.
  let row = @username/gpui-bindings.create_div()
  ignore(@username/gpui-bindings.set_flex_row(row))
  ignore(@username/gpui-bindings.set_gap(row, 12.0))
  ignore(
    @username/gpui-bindings.add_child(
      row,
      make_button("btn-decrement", "-1", BTN_DECREMENT, 200, 80, 80),
    ),
  )
  ignore(
    @username/gpui-bindings.add_child(
      row,
      make_button("btn-reset", "Reset", BTN_RESET, 92, 98, 110),
    ),
  )
  ignore(
    @username/gpui-bindings.add_child(
      row,
      make_button("btn-increment", "+1", BTN_INCREMENT, 70, 160, 95),
    ),
  )
  ignore(
    @username/gpui-bindings.add_child(
      row,
      make_button("btn-increment-10", "+10", BTN_INCREMENT_10, 70, 110, 230),
    ),
  )
  ignore(@username/gpui-bindings.add_child(root, row))

  let hint = @username/gpui-bindings.create_text(
    "keys:  k +1    j -1    r reset", 130, 135, 148, 14.0,
  )
  ignore(@username/gpui-bindings.add_child(root, hint))

  @username/gpui-bindings.set_root(root)
  @username/gpui-bindings.commit_tree()
}
