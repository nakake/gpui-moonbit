// Versioned event envelope decoding (RFC 0001 §3.2).
//
// Rust (gpui-sys) calls the single exported `dispatch(version, kind, view,
// data_a, data_b)` callback; the five i32 slots carry a versioned envelope
// (architecture.md §4b):
//   slot 0 = ABI_VERSION (a stale Rust binary is rejected at runtime)
//   slot 1 = event kind (EVENT_CLICK / EVENT_KEY / EVENT_TEXT / EVENT_NAMED_KEY)
//   slot 2 = view id (routes the rebuild target)
//   slot 3–4 = kind-dependent payload
// `decode_event` turns the raw slots into a typed `Event` that the handler
// registry dispatches. `EVENT_TEXT` carries a token + byte length; the UTF-8
// payload is copied synchronously from Rust's event queue
// (`gpui_event_copy_text`) before decoding returns, because 64-bit pointers do
// not fit in the i32 slots.

///|
/// 5 スロット envelope からデコード済みのイベントです。`decode_event` が生の
/// `(version, kind, data_a, data_b)` をこの型へ変換し、`HandlerRegistry` が kind ごとに
/// 型付きハンドラへ配送します。新しいイベント種別（例: RFC 0002 の `Async(Bytes)`）は
/// variant の追加として表現でき、envelope のデコードとハンドラ配送は kind の追加に
pub(all) enum Event {
  Click(Int) // click_id（HandlerRegistry 発行のハンドラ id）
  Key(Int, Int) // codepoint, modifier bits
  Text(String) // 入力テキスト（UTF-8 デコード済み）
  NamedKey(Int, Int) // named_key_id, modifier bits
  Async(Bytes) // 注入イベント（RFC 0002）。ペイロードは opaque bytes で解釈は消費側の契約
  Unknown
}

///|
/// 生の envelope スロットを `Event` へデコードします。`version` が `ABI_VERSION` と
/// 不一致の場合（stale な Rust バイナリ）は `Unknown` を返します。`EVENT_TEXT` は
/// `data_a` = token、`data_b` = バイト長で、Rust のイベントキューからペイロードを
/// 同期的にコピーしてから UTF-8 デコードします（コピー失敗・不正 UTF-8 はそれぞれ
/// `Unknown` / 空文字列になります）。
pub fn decode_event(
  version : Int,
  kind : Int,
  data_a : Int,
  data_b : Int,
) -> Event {
  // Runtime version handshake: reject a stale Rust binary.
  if version != ABI_VERSION {
    return Unknown
  }
  if kind == EVENT_CLICK {
    Click(data_a)
  } else if kind == EVENT_KEY {
    Key(data_a, data_b)
  } else if kind == EVENT_TEXT {
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
  } else if kind == EVENT_NAMED_KEY {
    NamedKey(data_a, data_b)
  } else if kind == EVENT_ASYNC {
    // RFC 0002 §3.5: data_a = token, data_b = byte length. The opaque payload
    // rides the same token+copy mechanism as EVENT_TEXT and must be copied
    // synchronously before dispatch returns.
    Async(copy_async_payload(data_a, data_b))
  } else {
    Unknown
  }
}
