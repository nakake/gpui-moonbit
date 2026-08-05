// Library-owned dispatch entry point (RFC 0004, issue #125).
//
// The Rust staticlib resolves exactly ONE MoonBit callback, by mangled symbol
// name (`gpui-sys/mb_symbol.txt` → `#[link_name]` in build.rs). That symbol used
// to be the Counter demo's `app.dispatch`, which nailed the library to one
// concrete app: a consumer could not supply its own without forking the build
// driver. The symbol now belongs to the library — `dispatch_entry` — and apps
// install their own handler at startup with `register_dispatch`.
//
// `dispatch_entry` is pure delegation and holds no policy: the version
// handshake and event decoding stay in `framework_dispatch` (RFC 0001 §3.4), so
// the entry's only job is to keep the link-time contract stable.
//
// Threading: `mb_dispatch` is main-thread-only (RFC 0002 §2-1) and registration
// is documented as "before run_window, on the main thread", so the slot needs no
// lock.

///|
let dispatch_slot : Ref[(Int, Int, Int, Int, Int) -> Int] = { val: no_dispatch }

///|
let warned_unregistered : Ref[Bool] = { val: false }

// Default handler for a program that never registered one. Returning 0 is a
// legal ABI answer ("nothing changed" — Rust simply skips `cx.notify()`), which
// keeps dispatch-less builds (link checks, headless round-trips) working without
// an abort. It is not silent, though: EVENT_ASYNC clears its queue after the
// dispatch returns (RFC 0002 §3.4), so a forgotten `register_dispatch` shows up
// as events vanishing. One line, once — a per-event warning would flood a
// streaming app.
//
// The line goes to stdout: MoonBit core exposes no stderr writer, and reaching
// fd 2 would mean either a new C export (ruled out by RFC 0004 §5) or a native
// stub in the library's root package, which every consumer would then have to
// compile. RFC 0004 §8-1 left the destination open for exactly this reason.

///|
fn no_dispatch(
  _version : Int,
  _kind : Int,
  _view : Int,
  _data_a : Int,
  _data_b : Int,
) -> Int {
  if !warned_unregistered.val {
    warned_unregistered.val = true
    println(
      "[gpui-bindings] warning: no dispatch registered; events are being dropped. " +
      "Call @nakake/gpui-bindings.register_dispatch(...) before run_window.",
    )
  }
  0
}

///|
/// Rust がリンクする唯一の C 可視エントリポイントです。`register_dispatch` で登録
/// されたクロージャへそのまま委譲し、戻り値（0 = 変化なし / 1 = 再描画）もそのまま
/// 返します。未登録なら 0 を返し、初回だけ警告を 1 行出します。
///
/// アプリがこれを直接呼ぶ必要はありません（Rust 側のイベント配送が呼びます）。
/// テストから登録済みの経路を検証する用途では直接呼べます。
pub fn dispatch_entry(
  version : Int,
  kind : Int,
  view : Int,
  data_a : Int,
  data_b : Int,
) -> Int {
  (dispatch_slot.val)(version, kind, view, data_a, data_b)
}

// DCE anchor: `dispatch_entry` is only ever called from Rust, through a symbol
// MoonBit's dead-code elimination cannot see. Anchoring it here — reachable from
// `register_dispatch`, which every app calls — is what lets consumers drop the
// `let _keep : (Int, Int, Int, Int, Int) -> Int = …` line they used to write in
// `main` (RFC 0004 §3.4).

///|
let keep_dispatch_entry : (Int, Int, Int, Int, Int) -> Int = dispatch_entry

///|
/// アプリの dispatch を登録します。`run_window` より前に、メインスレッドから呼んで
/// ください（実行時ガードはありません）。
///
/// 再登録は last-wins で、これがテストから dispatch を差し替える正規の手段です。
/// 通常は `framework_dispatch` を呼ぶだけの関数を渡します:
///
/// ```moonbit nocheck
/// fn dispatch(
///   version : Int,
///   kind : Int,
///   view : Int,
///   data_a : Int,
///   data_b : Int,
/// ) -> Int {
///   @nakake/gpui-bindings.framework_dispatch(
///     ctx, version, kind, view, data_a, data_b, rebuild,
///   )
/// }
///
/// fn main {
///   @nakake/gpui-bindings.register_dispatch(dispatch)
///   ...
/// }
/// ```
pub fn register_dispatch(f : (Int, Int, Int, Int, Int) -> Int) -> Unit {
  dispatch_slot.val = f
  ignore(keep_dispatch_entry)
}
