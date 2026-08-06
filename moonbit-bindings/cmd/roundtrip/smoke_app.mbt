// The round-trip smoke's own app (issue #125, RFC 0004 §4).
//
// `cmd/roundtrip` is the only test that drives the callback through the real
// linked path — MoonBit → C → Rust → C → MoonBit — so it needs an app of its
// own now that the Counter demo lives in `examples/counter`, a separate module
// the library cannot import. This is the smallest app that still covers what
// the smoke asserts:
//
//   - a keyed count card, so both rebuild branches are reachable: the full
//     `build_tree` (the committed tree has no such key yet) and the incremental
//     `update_text` (it does);
//   - a click handler whose registry-issued id the smoke replays;
//   - a key handler ('k' → +1), the same route the demo uses;
//   - a text input whose submit handler pulls across the FFI, which fails
//     headless and must leave state untouched.
//
// Handlers `set` the signal and never report "changed"; the framework decides
// whether to rebuild from the store's dirty tracking (RFC 0001 §3.4).

///|
let store : @nakake/gpui-bindings.Store = @nakake/gpui-bindings.Store::new()

///|
let count_cell : @nakake/gpui-bindings.CellId[Int] = store.new_cell(0)

///|
let count : @nakake/gpui-bindings.Signal[Int] = store.signal(count_cell)

// Stable key for the count card. `update_text` addresses it for the in-place
// update; the full rebuild keys the same div so the two paths agree.

///|
const COUNT_KEY : String = "count-label"

///|
const KEY_K : Int = 107 // 'k' → +1

///|
let handlers : @nakake/gpui-bindings.HandlerRegistry = {
  // The key handler is registered inside `handlers`' own initializer. MoonBit
  // only evaluates a top-level binding when something references it, so a
  // `_`-prefixed top-level registration would be silently dropped and the
  // handler would never fire.
  let r = @nakake/gpui-bindings.HandlerRegistry::new()
  let _ = r.on_key(fn(code, _mods) {
    if code == KEY_K {
      count.set(store, count.get(store) + 1)
    }
  })
  r
}

///|
let btn_increment : @nakake/gpui-bindings.HandlerId = handlers.on_click(fn(
  _view,
) {
  count.set(store, count.get(store) + 1)
})

///|
let prompt_input : @nakake/gpui-bindings.InputId = {
  let id = handlers.new_input_id()
  handlers.on_submit(id, fn(view) {
    // Pull the submitted text across the FFI. Headless there is no committed
    // text model, so this fails and state stays put — which is exactly what the
    // smoke asserts (the dirty gate then reports 0).
    match @nakake/gpui-bindings.input_text(view, id.to_int()) {
      Ok(_) => count.set(store, count.get(store) + 1)
      Err(_) => ()
    }
  })
  id
}

///|
/// +1 ボタンの実ハンドラ id。id は共有カウンタで発行されるため登録順に依存する —
/// smoke 側でのハードコードは登録の追加・並べ替えで静かに壊れる。
fn increment_handler_id() -> Int {
  btn_increment.to_int()
}

///|
/// プロンプト入力の生 input_id（`increment_handler_id` と同じ規約）。
fn prompt_input_id() -> Int {
  prompt_input.to_int()
}

///|
/// カウント表示のテキスト。インクリメンタル経路とフルリビルド経路の両方がこれを使う。
/// 片方だけ書式を変えると更新のたびに表示が揺れるため、文字列は 1 箇所に閉じ込める。
fn count_label(n : Int) -> String {
  "Count: \{n}"
}

///|
let ctx : @nakake/gpui-bindings.RenderCtx = { view: 0, store, handlers }

///|
fn app_build_tree(view : Int) -> Result[Unit, Int] {
  let cb = @nakake/gpui-bindings.CommandBuffer::new()
  cb.div() // root
  cb.set_flex_col()
  cb.set_gap(12.0)
  cb.set_padding(16.0)

  // Count card: keyed so `update_text` can address its text child.
  cb.div()
  cb.set_key(COUNT_KEY)
  cb.text(count_label(count.get(store)), 120, 200, 255, 24.0)
  cb.add_child()
  cb.add_child()

  // The button carries the registry-issued click id into the wire stream.
  @nakake/gpui-bindings.button(cb, {
    key: "btn-increment",
    label: "+1",
    color: @nakake/gpui-bindings.Color::rgb(70, 160, 95),
    on_click: btn_increment,
  })
  cb.add_child()

  // Editable input: the submit handler above pulls through it.
  @nakake/gpui-bindings.text_input(cb, {
    key: "prompt-input",
    input_id: prompt_input,
    placeholder: "type a number, press Enter",
    min_width: 200,
  })
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
      // Incremental first, full rebuild on failure (issue #10). The smoke drives
      // both branches: the first click falls back (the committed tree is the
      // round-trip's own text tree, which has no COUNT_KEY), the later key event
      // updates the now-present label in place.
      match
        @nakake/gpui-bindings.update_text(
          v, COUNT_KEY, count_label(count.get(store)),
        ) {
        Ok(_) => Ok(())
        Err(_) => app_build_tree(v)
      }
    },
  )
}
