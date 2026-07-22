// Interactive app: state + logic, written in MoonBit.
//
// `dispatch` is the single event entry point that Rust (gpui-sys) calls via its
// compiled symbol. The four i32 slots carry a versioned event envelope:
//   (abi_version, event_kind, data_a, data_b)
// Slot 0 is always ABI_VERSION so a stale Rust binary is rejected at runtime.
// Slot 1 selects the event kind; slots 2–3 are kind-dependent:
//   EVENT_CLICK: data_a = click_id, data_b = 0
//   EVENT_KEY:   data_a = codepoint, data_b = modifier bits
//   EVENT_TEXT:  data_a = token, data_b = byte length (copy via gpui_event_copy_text)
//
// NOTE: changing `dispatch`'s signature does NOT change the mangled symbol name
// (MoonBit mangling excludes types), so the Rust `extern` must be kept in sync —
// it is generated from a template in `gpui-sys/build.rs`.

// Direct FFI: declared here (not in the root package) so `moon test` on
// gpui-bindings never compiles a reference to the Rust-only symbol.
///|
#borrow(buf)
extern "C" fn gpui_event_copy_text_ffi(
  token : Int,
  buf : Bytes,
  len : Int,
) -> Int = "gpui_event_copy_text"

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
  Text(String) // typed text (UTF-8 decoded)
  Unknown
}

///|
fn decode(version : Int, kind : Int, data_a : Int, data_b : Int) -> Event {
  // Runtime version handshake: reject a stale Rust binary.
  if version != @username/gpui-bindings.ABI_VERSION {
    return Unknown
  }
  if kind == @username/gpui-bindings.EVENT_CLICK {
    Click(data_a)
  } else if kind == @username/gpui-bindings.EVENT_KEY {
    Key(data_a, data_b)
  } else if kind == @username/gpui-bindings.EVENT_TEXT {
    // data_a = token, data_b = byte length. Copy the UTF-8 payload from
    // Rust's event queue synchronously before returning from dispatch.
    let len = data_b
    let buf = Bytes::make(len, b'\x00')
    let copied = gpui_event_copy_text_ffi(data_a, buf, len)
    if copied > 0 {
      let text = @utf8.decode(buf[0:copied]) catch { _ => "" }
      Text(text)
    } else {
      Unknown
    }
  } else {
    Unknown
  }
}

///|
pub fn dispatch(version : Int, kind : Int, data_a : Int, data_b : Int) -> Int {
  rebuild_if_changed(
    apply_event(decode(version, kind, data_a, data_b)),
    build_tree,
  )
}

///|
fn apply_event(event : Event) -> Int {
  match event {
    Click(click_id) => on_click(click_id)
    Key(code, mods) => on_key(code, mods)
    Text(text) => on_text(text)
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
  if all_digits && value != count[0] {
    count[0] = value
    1
  } else {
    0
  }
}

// Build one labelled, clickable button onto the command buffer. The button div
// is pushed, configured, given a text label child, and left on the stack so the
// caller can `add_child` it into its parent.

///|
fn make_button(
  cb : @username/gpui-bindings.CommandBuffer,
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
pub fn build_tree() -> Unit {
  let cb = @username/gpui-bindings.CommandBuffer::new()
  cb.div() // root
  cb.set_bg(28, 30, 38)
  cb.set_flex_col()
  cb.set_center()
  cb.set_gap(28.0)

  cb.text("Counter", 236, 239, 245, 30.0)
  cb.add_child()
  cb.text("Count: \{count[0]}", 120, 200, 255, 44.0)
  cb.add_child()

  // A row of buttons; each is a distinct click_id routed in on_click.
  cb.div() // row
  cb.set_flex_row()
  cb.set_gap(12.0)
  make_button(cb, "btn-decrement", "-1", BTN_DECREMENT, 200, 80, 80)
  cb.add_child()
  make_button(cb, "btn-reset", "Reset", BTN_RESET, 92, 98, 110)
  cb.add_child()
  make_button(cb, "btn-increment", "+1", BTN_INCREMENT, 70, 160, 95)
  cb.add_child()
  make_button(cb, "btn-increment-10", "+10", BTN_INCREMENT_10, 70, 110, 230)
  cb.add_child()
  cb.add_child() // attach the row to the root

  cb.text("keys:  k +1    j -1    r reset", 130, 135, 148, 14.0)
  cb.add_child()

  cb.set_root()
  @username/gpui-bindings.build_tree(0, cb)
}
