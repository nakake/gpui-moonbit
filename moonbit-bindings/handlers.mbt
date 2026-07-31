// Typed handler registry (RFC 0001 §3.2, G12).
//
// Closures cannot cross the C ABI (moonbit-native-notes.md §6), but integer
// ids can. The registry registers MoonBit closures and issues an `Int` id that
// `set_on_click` writes into the wire stream; when an event arrives, the
// registry looks the id up and invokes the typed closure. `click_id` changes
// role from "action meaning decoded by an int switch" to "registry key".
//
// Ids are issued ONCE at setup and never re-issued per rebuild: a rebuild only
// rewrites the same ids via `set_on_click`, so the id ↔ closure correspondence
// stays stable.
//
// Click handlers are single-dispatch (one handler per id, keyed by the
// envelope's `click_id`). Key / named-key / text events are app-level (they
// reach the focused outer container, not a node), so those registries are
// fan-out lists invoked in registration order.

///|
/// クリックハンドラ。envelope の view id を受け取ります。状態を変更するハンドラは
/// signal / store を通じて変更し（RFC 0001 §3.4）、「変わったか」を戻り値で報告しません。
pub type ClickHandler = (Int) -> Unit

///|
/// キーハンドラ（アプリ級。codepoint と modifier bits を受け取ります）。
/// ノード単位のキーフォーカスは GPUI 側のフォーカスモデル拡張（G16/G19 隣接）を要する
/// ため、本レジストリはアプリ級の登録口に留めます。
pub type KeyHandler = (Int, Int) -> Unit

///|
/// 名前付きキーハンドラ（アプリ級。named_key_id と modifier bits を受け取ります）。
pub type NamedKeyHandler = (Int, Int) -> Unit

///|
/// テキストハンドラ（アプリ級。確定テキストを受け取ります）。
pub type TextHandler = (String) -> Unit

///|
/// 型付きイベントハンドラのレジストリです。クロージャを登録して整数 id を発行し、
/// envelope の `(view, click_id)` / kind ペイロードを対応する型付きクロージャへ配送
/// します。クリックは id ごとの単一配送、キー / 名前付きキー / テキストは登録順の
/// 全配信（アプリ級イベント）です。
pub(all) struct HandlerRegistry {
  click : Map[Int, ClickHandler]
  key : Array[(Int, KeyHandler)]
  named_key : Array[(Int, NamedKeyHandler)]
  text : Array[(Int, TextHandler)]
  mut next_id : Int
}

///|
/// 空のレジストリを作成します。id は 1 から単調に発行されます（0 は「未登録」の
/// 慣習値として予約されます）。
pub fn HandlerRegistry::new() -> HandlerRegistry {
  { click: Map([]), key: [], named_key: [], text: [], next_id: 1 }
}

///|
/// クリックハンドラを登録し、`set_on_click` に渡す id を発行します。
pub fn HandlerRegistry::on_click(self : HandlerRegistry, h : ClickHandler) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  self.click[id] = h
  id
}

///|
/// アプリ級のキーハンドラを登録し、id を発行します。
pub fn HandlerRegistry::on_key(self : HandlerRegistry, h : KeyHandler) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  self.key.push((id, h))
  id
}

///|
/// アプリ級の名前付きキーハンドラを登録し、id を発行します。
pub fn HandlerRegistry::on_named_key(self : HandlerRegistry, h : NamedKeyHandler) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  self.named_key.push((id, h))
  id
}

///|
/// アプリ級のテキストハンドラを登録し、id を発行します。
pub fn HandlerRegistry::on_text(self : HandlerRegistry, h : TextHandler) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  self.text.push((id, h))
  id
}

///|
/// デコード済みの `Event` を対応する型付きハンドラへ配送します。`dispatch` から
/// 呼ばれます。未知のクリック id は no-op です（従来の `on_click` の else 分岐に相当）。
pub fn HandlerRegistry::dispatch(self : HandlerRegistry, event : Event, view : Int) -> Unit {
  match event {
    Click(click_id) =>
      match self.click.get(click_id) {
        Some(h) => h(view)
        None => ()
      }
    Key(code, mods) =>
      for entry in self.key {
        (entry.1)(code, mods)
      }
    Text(text) =>
      for entry in self.text {
        (entry.1)(text)
      }
    NamedKey(id, mods) =>
      for entry in self.named_key {
        (entry.1)(id, mods)
      }
    Unknown => ()
  }
}
