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
// envelope's `click_id`). Text-input events (RFC 0003) are also single-
// dispatch, keyed by the envelope's `input_id`; unlike click ids (registry-
// issued by `on_click`), input ids are issued by `new_input_id` and written
// into the wire stream by `CommandBuffer::text_input`. Key / named-key / text
// events are app-level (they reach the focused outer container, not a node),
// so those registries are fan-out lists invoked in registration order.

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
/// 非同期注入ハンドラ（RFC 0002。opaque ペイロードを受け取ります。解釈は消費側の契約）。
pub type AsyncHandler = (Bytes) -> Unit

///|
/// 入力変化ハンドラ（RFC 0003。envelope の view id を受け取ります）。現在のテキストは
/// 必要に応じて `input_text(view, input_id)` で pull します（通知専用、ペイロードなし）。
pub type InputChangedHandler = (Int) -> Unit

///|
/// 入力確定ハンドラ（RFC 0003。フォーカス中の input での Enter。envelope の view id を
/// 受け取ります）。
pub type InputSubmitHandler = (Int) -> Unit

///|
/// クリックハンドラの型付き id です。中身は `HandlerRegistry` が発行する整数ですが、
/// 型で区別することで生の `click_id`（envelope の `data_a`）や他の整数と混同する
/// ことを防ぎます。`set_on_click` には `to_int()` で渡します。
pub(all) struct HandlerId {
  raw : Int
}

///|
/// ハンドラ id を `set_on_click` に渡せる生の整数へ変換します。
pub fn HandlerId::to_int(self : HandlerId) -> Int {
  self.raw
}

///|
/// テキスト入力 widget の型付き id です（RFC 0003）。中身は `HandlerRegistry::new_input_id`
/// が発行する整数ですが、型で区別することで `HandlerId` や envelope の生の `input_id`
/// と混同することを防ぎます。`CommandBuffer::text_input` には `to_int()` で渡します。
pub(all) struct InputId {
  raw : Int
}

///|
/// 入力 id を `CommandBuffer::text_input` に渡せる生の整数へ変換します。
pub fn InputId::to_int(self : InputId) -> Int {
  self.raw
}

///|
/// 型付きイベントハンドラのレジストリです。クロージャを登録して整数 id を発行し、
/// envelope の `(view, click_id)` / kind ペイロードを対応する型付きクロージャへ配送
/// クリックとテキスト入力イベント（RFC 0003）は id ごとの単一配送、キー / 名前付き
/// キー / テキストは登録順の全配信（アプリ級イベント）です。
pub(all) struct HandlerRegistry {
  click : Map[Int, ClickHandler]
  input_changed : Map[Int, InputChangedHandler]
  input_submit : Map[Int, InputSubmitHandler]
  key : Array[(Int, KeyHandler)]
  named_key : Array[(Int, NamedKeyHandler)]
  text : Array[(Int, TextHandler)]
  async_ : Array[(Int, AsyncHandler)]
  mut next_id : Int
}

///|
/// 空のレジストリを作成します。id は 1 から単調に発行されます（0 は「未登録」の
/// 慣習値として予約されます）。
pub fn HandlerRegistry::new() -> HandlerRegistry {
  {
    click: Map([]),
    input_changed: Map([]),
    input_submit: Map([]),
    key: [],
    named_key: [],
    text: [],
    async_: [],
    next_id: 1,
  }
}

///|
/// クリックハンドラを登録し、`set_on_click` に渡す型付き id を発行します。
pub fn HandlerRegistry::on_click(
  self : HandlerRegistry,
  h : ClickHandler,
) -> HandlerId {
  let id = self.next_id
  self.next_id = id + 1
  self.click[id] = h
  { raw: id }
}

///|
/// テキスト入力 widget の id を発行します（RFC 0003）。click id と同じ共有カウンタから
/// 単調に発行されますが、レジストリへのハンドラ登録は伴いません。発行した id は
/// `CommandBuffer::text_input` でワイヤに書き込み、`on_input_changed` / `on_submit` で
/// その id へのハンドラを登録します。
pub fn HandlerRegistry::new_input_id(self : HandlerRegistry) -> InputId {
  let id = self.next_id
  self.next_id = id + 1
  { raw: id }
}

///|
/// `input_id` のテキスト入力に対する変化ハンドラ（RFC 0003、`EVENT_INPUT_CHANGED`）を
/// 登録します。id ごとの単一配送で、同じ id への再登録は前のハンドラを置き換えます。
pub fn HandlerRegistry::on_input_changed(
  self : HandlerRegistry,
  input_id : InputId,
  h : InputChangedHandler,
) -> Unit {
  self.input_changed[input_id.raw] = h
}

///|
/// `input_id` のテキスト入力に対する確定ハンドラ（RFC 0003、`EVENT_INPUT_SUBMIT`）を
/// 登録します。id ごとの単一配送で、同じ id への再登録は前のハンドラを置き換えます。
pub fn HandlerRegistry::on_submit(
  self : HandlerRegistry,
  input_id : InputId,
  h : InputSubmitHandler,
) -> Unit {
  self.input_submit[input_id.raw] = h
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
pub fn HandlerRegistry::on_named_key(
  self : HandlerRegistry,
  h : NamedKeyHandler,
) -> Int {
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
/// 非同期注入ハンドラ（RFC 0002）を登録し、id を発行します。登録順の全配信です。
pub fn HandlerRegistry::on_async(
  self : HandlerRegistry,
  h : AsyncHandler,
) -> Int {
  let id = self.next_id
  self.next_id = id + 1
  self.async_.push((id, h))
  id
}

///|
/// デコード済みの `Event` を対応する型付きハンドラへ配送します。`dispatch` から
/// 呼ばれます。未知のクリック id は no-op です（従来の `on_click` の else 分岐に相当）。
pub fn HandlerRegistry::dispatch(
  self : HandlerRegistry,
  event : Event,
  view : Int,
) -> Unit {
  match event {
    Click(click_id) =>
      match self.click.get(click_id) {
        Some(h) => h(view)
        None => ()
      }
    InputChanged(input_id) =>
      match self.input_changed.get(input_id) {
        Some(h) => h(view)
        None => ()
      }
    InputSubmit(input_id) =>
      match self.input_submit.get(input_id) {
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
    Async(payload) =>
      for entry in self.async_ {
        (entry.1)(payload)
      }
    Unknown => ()
  }
}
